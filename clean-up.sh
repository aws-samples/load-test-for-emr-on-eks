#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -euo pipefail

# ============================================================
# Load environment variables
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/env.sh" ]; then
    echo "Error: env.sh not found in ${SCRIPT_DIR}"
    exit 1
fi
source "${SCRIPT_DIR}/env.sh"

# Helper: safe delete — prints status, doesn't exit on failure
safe_run() {
    local desc="$1"
    shift
    echo "  -> ${desc}"
    if ! "$@" 2>/dev/null; then
        echo "     [skipped or already removed]"
    fi
}

# Helper: terminate every EC2 instance tagged to a cluster and wait for them to
# go away. Karpenter-launched nodes are NOT owned by the eksctl CloudFormation
# stacks, so if Karpenter removal (step 3) fails or the controller is already
# gone, `eksctl delete cluster` leaves those nodes running. Each holds an ENI in
# a private subnet, which then blocks the subnet -- and the whole cluster stack
# -- from deleting (DELETE_FAILED), stranding a running instance that keeps
# costing money. Sweeping by the eks:eks-cluster-name / kubernetes.io/cluster
# tags catches them regardless of Karpenter's state. Idempotent: no instances ->
# no-op.
sweep_cluster_nodes() {
    local CL_NAME="$1"
    local ids
    # Match either tag key EKS/Karpenter apply to managed nodes. NOTE: match on
    # the tag KEY, not the value. eks:eks-cluster-name has value=<cluster>, but
    # kubernetes.io/cluster/<cluster> has value "owned"/"shared" (never the
    # cluster name) -- so a value-only match would silently skip Karpenter nodes
    # (which carry only the kubernetes.io/cluster/ tag) and leave them running.
    ids=$(aws ec2 describe-instances --region "${AWS_REGION}" \
        --filters "Name=instance-state-name,Values=running,pending,stopping,stopped" \
                  "Name=tag-key,Values=kubernetes.io/cluster/${CL_NAME},eks:eks-cluster-name" \
        --query "Reservations[].Instances[?Tags[?Key=='eks:eks-cluster-name' && Value=='${CL_NAME}'] || Tags[?Key=='kubernetes.io/cluster/${CL_NAME}']].InstanceId" \
        --output text 2>/dev/null | tr '\t' '\n' | sort -u | tr '\n' ' ')
    ids=$(echo "$ids" | xargs 2>/dev/null || true)
    if [ -z "$ids" ]; then
        echo "  -> No leftover EC2 instances tagged to ${CL_NAME}"
        return 0
    fi
    echo "  -> Terminating leftover EC2 instances: ${ids}"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${ids} \
        --query 'TerminatingInstances[].InstanceId' --output text 2>/dev/null || true
    echo "     waiting for termination ..."
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids ${ids} 2>/dev/null || true
}

# ============================================================
# Discover ALL EKS clusters matching the LOAD_TEST_PREFIX
# ============================================================
echo "============================================================"
echo " Discovering EKS clusters with prefix: ${LOAD_TEST_PREFIX}"
echo " Region: ${AWS_REGION}"
echo " Account: ${ACCOUNT_ID}"
echo "============================================================"

ALL_CLUSTERS=$(aws eks list-clusters --region "${AWS_REGION}" \
    --query "clusters[?starts_with(@, '${LOAD_TEST_PREFIX}')]" \
    --output text 2>/dev/null || true)

if [ -z "$ALL_CLUSTERS" ]; then
    echo "No EKS clusters found matching prefix '${LOAD_TEST_PREFIX}'. Will still clean up IAM, S3, ECR, KMS..."
    ALL_CLUSTERS=""
fi

echo "Found clusters: ${ALL_CLUSTERS:-"(none)"}"
echo ""

# ============================================================
# Per-cluster cleanup function
# ============================================================
cleanup_cluster() {
    local CL_NAME="$1"
    # Read the EKS version live from the cluster (the cluster name is a
    # user-supplied literal, so it cannot be parsed for a version). Falls back
    # to env.sh's EKS_VERSION if the cluster is already gone.
    local CL_VERSION
    CL_VERSION=$(aws eks describe-cluster --name "$CL_NAME" --region "$AWS_REGION" \
        --query 'cluster.version' --output text 2>/dev/null || true)
    if [ -z "$CL_VERSION" ] || [ "$CL_VERSION" = "None" ]; then
        CL_VERSION="${EKS_VERSION}"
    fi
    local CL_BUCKET="emr-on-${CL_NAME}-${ACCOUNT_ID}-${AWS_REGION}"
    local CL_EXECUTION_ROLE="emr-on-${CL_NAME}-execution-role"
    local CL_EXECUTION_ROLE_POLICY="${CL_NAME}-SparkJobS3AccessPolicy"
    local CL_LOCUST_EKS_ROLE="${CL_NAME}-locust-role"

    echo ""
    echo "############################################################"
    echo "# Cleaning up cluster: ${CL_NAME} (EKS ${CL_VERSION})"
    echo "############################################################"

    # ----------------------------------------------------------
    # 1. Cancel running EMR job runs & delete EMR virtual clusters
    # ----------------------------------------------------------
    echo ""
    echo "  [${CL_NAME}] 1. Cleaning up EMR virtual clusters ..."

    local VC_IDS
    VC_IDS=$(aws emr-containers list-virtual-clusters \
        --region "$AWS_REGION" \
        --query "virtualClusters[?(state=='RUNNING' || state=='TERMINATING') && contains(containerProvider.id, '${CL_NAME}')].id" \
        --output text 2>/dev/null || true)

    if [ -n "$VC_IDS" ]; then
        for vc_id in $VC_IDS; do
            echo "    Cancelling running jobs in VC: ${vc_id}"
            local RUNNING_JOBS
            RUNNING_JOBS=$(aws emr-containers list-job-runs \
                --virtual-cluster-id "$vc_id" \
                --region "$AWS_REGION" \
                --states PENDING SUBMITTED RUNNING \
                --query "jobRuns[].id" --output text 2>/dev/null || true)
            for job_id in $RUNNING_JOBS; do
                safe_run "Cancel job ${job_id}" \
                    aws emr-containers cancel-job-run --id "$job_id" --virtual-cluster-id "$vc_id" --region "$AWS_REGION"
            done
            safe_run "Delete virtual cluster ${vc_id}" \
                aws emr-containers delete-virtual-cluster --id "$vc_id" --region "$AWS_REGION"
        done
        echo "    Waiting for virtual clusters to terminate..."
        sleep 30
    else
        echo "    No virtual clusters found."
    fi

    # ----------------------------------------------------------
    # 2. Switch kubectl context to this cluster
    # ----------------------------------------------------------
    echo ""
    echo "  [${CL_NAME}] 2. Connecting to EKS cluster ..."
    if ! aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CL_NAME}" 2>/dev/null; then
        echo "    Could not connect to ${CL_NAME} (may already be deleted). Skipping k8s cleanup."
        # Jump to IAM / non-k8s cleanup for this cluster
        _cleanup_cluster_iam "${CL_NAME}" "${CL_VERSION}" "${CL_BUCKET}" "${CL_EXECUTION_ROLE}" "${CL_EXECUTION_ROLE_POLICY}" "${CL_LOCUST_EKS_ROLE}"
        return
    fi

    # ----------------------------------------------------------
    # 3. Remove Karpenter
    # ----------------------------------------------------------
    echo ""
    echo "  [${CL_NAME}] 3. Removing Karpenter resources ..."

    if [ -f "${SCRIPT_DIR}/resources/karpenter/remove-karpenter.sh" ]; then
        bash "${SCRIPT_DIR}/resources/karpenter/remove-karpenter.sh" \
            eks-version="${CL_VERSION}" \
            karpenter-version="${KARPENTER_VERSION}" \
            cluster-name="${CL_NAME}" \
            aws-region="${AWS_REGION}" || echo "    [Karpenter removal encountered errors, continuing...]"
    else
        echo "    remove-karpenter.sh not found, cleaning up Karpenter manually..."
        kubectl delete nodepools --all --ignore-not-found --wait=false 2>/dev/null || true
        kubectl delete ec2nodeclasses --all --ignore-not-found --wait=false 2>/dev/null || true
        kubectl delete crd nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws nodeclaims.karpenter.sh --ignore-not-found 2>/dev/null || true

        if [ -f "./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml" ]; then
            kubectl delete -f "./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml" --ignore-not-found --wait=false 2>/dev/null || true
        fi

        # Karpenter IAM
        local KP_CTRL_ROLE="KarpenterControllerRole-${CL_NAME}"
        local KP_NODE_ROLE="KarpenterNodeRole-${CL_NAME}"
        for role in "$KP_CTRL_ROLE" "$KP_NODE_ROLE"; do
            if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
                for pa in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
                    safe_run "Detach ${pa} from ${role}" aws iam detach-role-policy --role-name "$role" --policy-arn "$pa"
                done
                for pn in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
                    safe_run "Delete inline ${pn} from ${role}" aws iam delete-role-policy --role-name "$role" --policy-name "$pn"
                done
                for prof in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
                    safe_run "Remove ${role} from profile ${prof}" aws iam remove-role-from-instance-profile --instance-profile-name "$prof" --role-name "$role"
                done
                safe_run "Delete role ${role}" aws iam delete-role --role-name "$role"
            fi
        done

        local KP_EBS_POLICY="KarpenterEBSEncryptionPolicy-${CL_NAME}"
        local KP_EBS_ARN
        KP_EBS_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${KP_EBS_POLICY}'].Arn" --output text 2>/dev/null || true)
        if [ -n "$KP_EBS_ARN" ] && [ "$KP_EBS_ARN" != "None" ]; then
            safe_run "Delete policy ${KP_EBS_POLICY}" aws iam delete-policy --policy-arn "$KP_EBS_ARN"
        fi

        safe_run "Delete Karpenter node access entry" \
            aws eks delete-access-entry --cluster-name "${CL_NAME}" --region "${AWS_REGION}" \
            --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${KP_NODE_ROLE}"

        local KP_STACK="karpenter-infra-${CL_NAME}"
        if aws cloudformation describe-stacks --stack-name "${KP_STACK}" --region "${AWS_REGION}" >/dev/null 2>&1; then
            safe_run "Delete CFN stack ${KP_STACK}" aws cloudformation delete-stack --stack-name "${KP_STACK}" --region "${AWS_REGION}"
            aws cloudformation wait stack-delete-complete --stack-name "${KP_STACK}" --region "${AWS_REGION}" 2>/dev/null || true
        fi
    fi

    # ----------------------------------------------------------
    # 4. Remove Locust resources
    # ----------------------------------------------------------
    echo ""
    echo "  [${CL_NAME}] 4. Removing Locust resources ..."

    kubectl delete locusttests --all -n locust --ignore-not-found --wait=false 2>/dev/null || true
    safe_run "Delete locust configmap" kubectl delete configmap emr-loadtest-locustfile -n locust --ignore-not-found
    safe_run "Uninstall locust-operator" helm uninstall locust-operator -n locust
    safe_run "Delete locust ClusterRoleBinding" kubectl delete clusterrolebinding default-locust-clusterrolebinding --ignore-not-found
    safe_run "Delete locust ClusterRole" kubectl delete clusterrole locust-operator-clusterrole --ignore-not-found
    safe_run "Delete locust namespace" kubectl delete namespace locust --ignore-not-found --wait=false

    safe_run "Delete Locust access entry" \
        aws eks delete-access-entry --cluster-name "${CL_NAME}" \
        --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${CL_LOCUST_EKS_ROLE}" --region "${AWS_REGION}"

    # ----------------------------------------------------------
    # 5. Remove Helm releases
    # ----------------------------------------------------------
    echo ""
    echo "  [${CL_NAME}] 5. Removing Helm releases ..."

    safe_run "Uninstall Prometheus" helm uninstall prometheus -n prometheus
    safe_run "Delete prometheus namespace" kubectl delete namespace prometheus --ignore-not-found --wait=false
    safe_run "Delete metrics server" kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --ignore-not-found
    safe_run "Uninstall AWS LB Controller" helm uninstall aws-load-balancer-controller -n kube-system
    safe_run "Uninstall custom-scheduler-eks" helm uninstall custom-scheduler-eks -n kube-system
    safe_run "Delete karpenter-svcmonitor" kubectl delete -f ./resources/monitor/karpenter-svcmonitor.yaml --ignore-not-found
    safe_run "Delete aws-cni-podmonitor" kubectl delete -f ./resources/monitor/aws-cni-podmonitor.yaml --ignore-not-found
    safe_run "Delete locust-podmonitor" kubectl delete -f ./resources/monitor/locust-podmonitor.yaml --ignore-not-found

    # ----------------------------------------------------------
    # 6. Clean up test namespaces
    # ----------------------------------------------------------
    echo ""
    echo "  [${CL_NAME}] 6. Cleaning up test namespaces ..."

    local TEST_NS
    TEST_NS=$(kubectl get namespaces -l "environment=${CL_NAME}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for ns in $TEST_NS; do
        safe_run "Delete namespace ${ns}" kubectl delete namespace "$ns" --ignore-not-found --wait=false
    done
    local EMR_NS
    EMR_NS=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep "^emr-" || true)
    for ns in $EMR_NS; do
        safe_run "Delete namespace ${ns}" kubectl delete namespace "$ns" --ignore-not-found --wait=false
    done

    # ----------------------------------------------------------
    # 7. Non-k8s cleanup (IAM, S3, EKS cluster deletion, etc.)
    # ----------------------------------------------------------
    _cleanup_cluster_iam "${CL_NAME}" "${CL_VERSION}" "${CL_BUCKET}" "${CL_EXECUTION_ROLE}" "${CL_EXECUTION_ROLE_POLICY}" "${CL_LOCUST_EKS_ROLE}"
}


# ============================================================
# Per-cluster IAM / non-k8s cleanup (also called when cluster is already gone)
# ============================================================
_cleanup_cluster_iam() {
    local CL_NAME="$1"
    local CL_VERSION="$2"
    local CL_BUCKET="$3"
    local CL_EXECUTION_ROLE="$4"
    local CL_EXECUTION_ROLE_POLICY="$5"
    local CL_LOCUST_EKS_ROLE="$6"

    # Monitoring uses the in-cluster kube-prometheus-stack (with built-in
    # Grafana), which is removed via `helm uninstall prometheus` above. No
    # Amazon Managed Grafana / Managed Prometheus workspaces are created, so
    # there is nothing to delete here.

    # -- Locust IRSA role --
    echo ""
    echo "  [${CL_NAME}] 7. Removing Locust IRSA role ..."
    if aws iam get-role --role-name "${CL_LOCUST_EKS_ROLE}" >/dev/null 2>&1; then
        for pa in $(aws iam list-attached-role-policies --role-name "${CL_LOCUST_EKS_ROLE}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
            safe_run "Detach ${pa}" aws iam detach-role-policy --role-name "${CL_LOCUST_EKS_ROLE}" --policy-arn "$pa"
        done
        for pn in $(aws iam list-role-policies --role-name "${CL_LOCUST_EKS_ROLE}" --query 'PolicyNames[]' --output text 2>/dev/null); do
            safe_run "Delete inline ${pn}" aws iam delete-role-policy --role-name "${CL_LOCUST_EKS_ROLE}" --policy-name "$pn"
        done
        safe_run "Delete role ${CL_LOCUST_EKS_ROLE}" aws iam delete-role --role-name "${CL_LOCUST_EKS_ROLE}"
    fi

    # -- EMR execution role & policy --
    echo ""
    echo "  [${CL_NAME}] 8. Removing EMR execution role & policy ..."
    if aws iam get-role --role-name "${CL_EXECUTION_ROLE}" >/dev/null 2>&1; then
        for pa in $(aws iam list-attached-role-policies --role-name "${CL_EXECUTION_ROLE}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
            safe_run "Detach ${pa}" aws iam detach-role-policy --role-name "${CL_EXECUTION_ROLE}" --policy-arn "$pa"
        done
        for pn in $(aws iam list-role-policies --role-name "${CL_EXECUTION_ROLE}" --query 'PolicyNames[]' --output text 2>/dev/null); do
            safe_run "Delete inline ${pn}" aws iam delete-role-policy --role-name "${CL_EXECUTION_ROLE}" --policy-name "$pn"
        done
        safe_run "Delete role ${CL_EXECUTION_ROLE}" aws iam delete-role --role-name "${CL_EXECUTION_ROLE}"
    fi
    local exec_pol_arn
    exec_pol_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${CL_EXECUTION_ROLE_POLICY}'].Arn" --output text 2>/dev/null || true)
    if [ -n "$exec_pol_arn" ] && [ "$exec_pol_arn" != "None" ]; then
        safe_run "Delete policy ${CL_EXECUTION_ROLE_POLICY}" aws iam delete-policy --policy-arn "$exec_pol_arn"
    fi

    # -- EBS CSI KMS inline policy --
    echo ""
    echo "  [${CL_NAME}] 9. Removing EBS CSI KMS inline policy ..."
    local ebs_role
    ebs_role=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CL_NAME}') && contains(RoleName, 'ebs-csi')].RoleName" --output text 2>/dev/null | head -1)
    if [ -n "$ebs_role" ]; then
        safe_run "Delete EBS-CSI-KMS-Policy from ${ebs_role}" aws iam delete-role-policy --role-name "$ebs_role" --policy-name "EBS-CSI-KMS-Policy"
    fi

    # -- S3 bucket --
    echo ""
    echo "  [${CL_NAME}] 10. Removing S3 bucket ${CL_BUCKET} ..."
    if aws s3api head-bucket --bucket "${CL_BUCKET}" 2>/dev/null; then
        aws s3 rm "s3://${CL_BUCKET}" --recursive 2>/dev/null || true
        safe_run "Delete bucket ${CL_BUCKET}" aws s3api delete-bucket --bucket "${CL_BUCKET}" --region "${AWS_REGION}"
    else
        echo "    Bucket not found, skipping."
    fi

    # -- Sweep Karpenter/EKS nodes BEFORE deleting the cluster --
    # eksctl only deletes what its stacks own; Karpenter nodes aren't among them,
    # so terminate them first or they orphan and their ENIs wedge the cluster
    # stack in DELETE_FAILED (see sweep_cluster_nodes).
    echo ""
    echo "  [${CL_NAME}] 10b. Terminating leftover EC2 nodes ..."
    sweep_cluster_nodes "${CL_NAME}"

    # -- Delete EKS cluster --
    echo ""
    echo "  [${CL_NAME}] 11. Deleting EKS cluster ..."
    if aws eks describe-cluster --name "${CL_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
        cp ./resources/eks-cluster-values.yaml ./resources/eks-cluster-values-${CL_NAME}.yaml
        sed -i='' 's|${AWS_REGION}|'"$AWS_REGION"'|g' ./resources/eks-cluster-values-${CL_NAME}.yaml
        sed -i='' 's|${CLUSTER_NAME}|'"$CL_NAME"'|g' ./resources/eks-cluster-values-${CL_NAME}.yaml
        sed -i='' 's|${EKS_VERSION}|'"$CL_VERSION"'|g' ./resources/eks-cluster-values-${CL_NAME}.yaml
        sed -i='' 's|${EKS_VPC_CIDR}|'"$EKS_VPC_CIDR"'|g' ./resources/eks-cluster-values-${CL_NAME}.yaml
        sed -i='' 's|${ACCOUNT_ID}|'"$ACCOUNT_ID"'|g' ./resources/eks-cluster-values-${CL_NAME}.yaml

        echo "    Deleting via eksctl (this may take 10-15 minutes)..."
        eksctl delete cluster -f ./resources/eks-cluster-values-${CL_NAME}.yaml --wait || {
            echo "    eksctl config-based delete failed, trying by name..."
            eksctl delete cluster --name "${CL_NAME}" --region "${AWS_REGION}" --wait || true
        }
        rm -f ./resources/eks-cluster-values-${CL_NAME}.yaml ./resources/eks-cluster-values-${CL_NAME}.yaml=
    else
        echo "    EKS cluster ${CL_NAME} not found, skipping."
    fi

    # -- Sweep remaining IAM roles for this cluster --
    echo ""
    echo "  [${CL_NAME}] 12. Sweeping remaining IAM roles ..."
    local leftover_roles
    leftover_roles=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CL_NAME}')].RoleName" --output text 2>/dev/null || true)
    for role in $leftover_roles; do
        echo "    Cleaning up leftover role: ${role}"
        for pa in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
            safe_run "Detach ${pa}" aws iam detach-role-policy --role-name "$role" --policy-arn "$pa"
        done
        for pn in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
            safe_run "Delete inline ${pn}" aws iam delete-role-policy --role-name "$role" --policy-name "$pn"
        done
        for prof in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
            safe_run "Remove from profile ${prof}" aws iam remove-role-from-instance-profile --instance-profile-name "$prof" --role-name "$role"
        done
        safe_run "Delete role ${role}" aws iam delete-role --role-name "$role"
    done

    # -- Sweep remaining IAM policies for this cluster --
    local leftover_pols
    leftover_pols=$(aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, '${CL_NAME}')].Arn" --output text 2>/dev/null || true)
    for pol_arn in $leftover_pols; do
        safe_run "Delete policy ${pol_arn}" aws iam delete-policy --policy-arn "$pol_arn"
    done

    # -- Sweep any nodes that outlived the cluster delete, so their ENIs don't
    # keep a subnet (and its stack) from deleting in the sweep below. --
    echo ""
    echo "  [${CL_NAME}] 12b. Re-checking for leftover EC2 nodes ..."
    sweep_cluster_nodes "${CL_NAME}"

    # -- Sweep remaining CloudFormation stacks for this cluster --
    echo ""
    echo "  [${CL_NAME}] 13. Sweeping remaining CloudFormation stacks ..."
    local leftover_stacks
    leftover_stacks=$(aws cloudformation list-stacks \
        --query "StackSummaries[?StackStatus!='DELETE_COMPLETE' && contains(StackName, '${CL_NAME}')].StackName" \
        --output text --region "${AWS_REGION}" 2>/dev/null || true)
    for stack in $leftover_stacks; do
        safe_run "Delete stack ${stack}" aws cloudformation delete-stack --stack-name "$stack" --region "${AWS_REGION}"
    done
    for stack in $leftover_stacks; do
        aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "${AWS_REGION}" 2>/dev/null || true
    done

    # -- Clean up generated files for this cluster --
    rm -f ./resources/eks-cluster-values-${CL_NAME}.yaml
    rm -f ./resources/eks-cluster-values-${CL_NAME}.yaml=
    rm -f ./resources/monitor/prometheus-values-${CL_NAME}.yaml
    rm -f ./resources/monitor/prometheus-values-${CL_NAME}.yaml=
    rm -f ./locust/locust-operator/eks-role-policy-${CL_NAME}.json
    rm -f ./examples/load-test-on-eks-${CL_NAME}.yaml

    echo ""
    echo "  [${CL_NAME}] Cluster cleanup complete."
}


# ============================================================
# MAIN: Loop through all discovered clusters
# ============================================================
for cluster in $ALL_CLUSTERS; do
    cleanup_cluster "$cluster"
done

# If no clusters were discovered but the env.sh cluster might have
# leftover IAM/S3/CFN resources (cluster already deleted), clean those too
if [ -z "$ALL_CLUSTERS" ]; then
    echo ""
    echo "No live clusters found. Cleaning up residual resources for ${CLUSTER_NAME}..."
    _cleanup_cluster_iam "${CLUSTER_NAME}" "${EKS_VERSION}" "${BUCKET_NAME}" "${EXECUTION_ROLE}" "${EXECUTION_ROLE_POLICY}" "${LOCUST_EKS_ROLE}"
fi

# ============================================================
# Shared resources (not per-cluster)
# ============================================================

echo ""
echo "==============================================="
echo " Cleaning up shared resources ..."
echo "==============================================="

# -- ECR repositories (shared across clusters) --
echo ""
echo "  Removing ECR repositories ..."
for repo in locust eks-spark-benchmark; do
    if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
        safe_run "Delete ECR repo ${repo} (force)" \
            aws ecr delete-repository --repository-name "$repo" --region "$AWS_REGION" --force
    else
        echo "  ECR repo ${repo} not found, skipping."
    fi
done

# -- KMS CMK (shared across clusters) --
echo ""
echo "  Removing KMS CMK ..."
CMK_KEY_ID=$(aws kms describe-key --key-id "alias/${CMK_ALIAS}" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || true)
if [ -n "$CMK_KEY_ID" ] && [ "$CMK_KEY_ID" != "None" ]; then
    safe_run "Delete KMS alias ${CMK_ALIAS}" aws kms delete-alias --alias-name "alias/${CMK_ALIAS}"
    safe_run "Schedule KMS key deletion (7-day wait)" aws kms schedule-key-deletion --key-id "$CMK_KEY_ID" --pending-window-in-days 7
else
    echo "  KMS key with alias ${CMK_ALIAS} not found, skipping."
fi

# -- Clean up local generated files (shared) --
echo ""
echo "  Cleaning up local generated files ..."
rm -f ./resources/karpenter/cloudformation-${KARPENTER_VERSION}.yaml
rm -f ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml
rm -f ./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml
rm -f ./locust/env.sh
rm -rf ./custom-scheduler-eks
rm -f ./resources/*.yaml=
rm -f ./resources/karpenter/*=
rm -f ./locust/locust-operator/*=
rm -f ./examples/*=

echo ""
echo "============================================================"
echo " Full cleanup completed."
echo "============================================================"
