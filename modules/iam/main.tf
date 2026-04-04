# IAM module: Per-cluster IRSA roles for all components
# Implements FR-004

locals {
  cluster_full_name = "${var.project_name}-${var.cluster_name}"
  oidc_provider_id  = replace(var.oidc_provider_url, "https://", "")
}

data "aws_caller_identity" "current" {}

# --- EMR on EKS Execution Role ---

resource "aws_iam_role" "emr_execution" {
  name = "emr-on-${local.cluster_full_name}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:emr-*:emr-containers-sa-*-*-${data.aws_caller_identity.current.account_id}-*"
          }
        }
      }
    ]
  })

  tags = { Cluster = var.cluster_name }
}

resource "aws_iam_role_policy" "emr_execution" {
  name = "emr-on-${local.cluster_full_name}-execution-policy"
  role = aws_iam_role.emr_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*",
          "arn:aws:s3:::blogpost-sparkoneks-us-east-1",
          "arn:aws:s3:::blogpost-sparkoneks-us-east-1/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [var.kms_key_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = ["arn:aws:logs:*:*:*"]
      }
    ]
  })
}

# --- Locust IRSA Role ---

resource "aws_iam_role" "locust" {
  name = "${local.cluster_full_name}-locust"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_id}:sub" = [
              "system:serviceaccount:locust:default",
              "system:serviceaccount:locust:locust-operator"
            ]
          }
        }
      }
    ]
  })

  tags = { Cluster = var.cluster_name }
}

resource "aws_iam_role_policy" "locust" {
  name = "${local.cluster_full_name}-locust"
  role = aws_iam_role.locust.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowIAMCreateServiceLinkedRole"
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = ["*"]
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = "emr-containers.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "emr-containers:CreateVirtualCluster",
          "emr-containers:ListVirtualClusters",
          "emr-containers:DescribeVirtualCluster",
          "emr-containers:DeleteVirtualCluster",
          "eks:DescribeCluster*",
          "eks:ListClusters",
          "eks:ListAccessEntries",
          "eks:DescribeAccessEntry",
          "eks:CreateAccessEntry",
          "eks:AssociateAccessPolicy"
        ]
        Resource = ["*"]
      },
      {
        Sid    = "AllowEMRStartJobRun"
        Effect = "Allow"
        Action = [
          "emr-containers:StartJobRun",
          "emr-containers:ListJobRuns",
          "emr-containers:DescribeJobRun",
          "emr-containers:CancelJobRun"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:Get*",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

# --- Karpenter Controller Role ---

resource "aws_iam_role" "karpenter_controller" {
  name = "${local.cluster_full_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:kube-system:karpenter"
          }
        }
      }
    ]
  })

  tags = { Cluster = var.cluster_name }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${local.cluster_full_name}-karpenter-controller"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances"
        ]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.karpenter_node.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfiles",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = ["arn:aws:ssm:*:*:parameter/aws/service/eks/optimized-ami/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "pricing:GetProducts"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = ["arn:aws:eks:*:*:cluster/${local.cluster_full_name}"]
      }
    ]
  })
}

# --- Karpenter Node Role ---

resource "aws_iam_role" "karpenter_node" {
  name = "${local.cluster_full_name}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = { Cluster = var.cluster_name }
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${local.cluster_full_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

# --- EBS CSI Driver Role ---

resource "aws_iam_role" "ebs_csi" {
  name = "${local.cluster_full_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })

  tags = { Cluster = var.cluster_name }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  name = "${local.cluster_full_name}-ebs-csi-kms"
  role = aws_iam_role.ebs_csi.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:CreateGrant"
        ]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

# --- AWS Load Balancer Controller Role ---

resource "aws_iam_role" "lb_controller" {
  name = "${local.cluster_full_name}-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = { Cluster = var.cluster_name }
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_iam_policy" "lb_controller" {
  name = "${local.cluster_full_name}-lb-controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:DescribeCoipPools",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeTargetGroups",
          "ec2:DescribeTargetHealth",
          "ec2:DescribeListeners",
          "ec2:DescribeRules",
          "elasticloadbalancing:*",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "iam:CreateServiceLinkedRole",
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "waf-regional:*",
          "wafv2:*",
          "shield:*",
          "tag:GetResources",
          "tag:TagResources"
        ]
        Resource = ["*"]
      }
    ]
  })
}
