# Single-cluster configuration example
# Usage: terraform apply -var-file=examples/single-cluster.tfvars

region       = "ap-southeast-2"
project_name = "emr-eks-load-test"

clusters = {
  "1-32" = {
    eks_version        = "1.32"
    karpenter_version  = "1.8.5"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]

    ops_node_group = {
      instance_type    = "m5.4xlarge"
      desired_capacity = 3
    }

    driver_nodepool = {
      cpu_limit           = "128"
      instance_categories = ["m", "c"]
      instance_sizes      = ["2xlarge", "4xlarge", "8xlarge"]
      capacity_types      = ["on-demand"]
    }

    executor_nodepool = {
      cpu_limit           = "3440"
      instance_categories = ["m", "r"]
      instance_sizes      = ["4xlarge", "8xlarge", "12xlarge", "16xlarge"]
      capacity_types      = ["spot", "on-demand"]
      consolidate_after   = "2m"
    }

    vpc_cni = {
      minimum_ip_target  = 32
      warm_ip_target     = 0
      warm_prefix_target = 1
    }

    locust = {
      workers           = 2
      users             = 4
      run_time          = "10m"
      emr_image_version = "7.9.0"
      job_ns_count      = 2
    }
  }
}
