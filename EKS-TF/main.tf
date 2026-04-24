# IAM Role for EKS Cluster
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_cluster_role" {
  name               = "eks-cluster-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Name        = "eks-cluster-role"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Attach EKS Cluster Policy - ONLY REQUIRED POLICY (AmazonEKSServicePolicy removed)
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

# Get VPC data
data "aws_vpc" "default" {
  default = true
}

# Security group for EKS cluster with restricted access
resource "aws_security_group" "eks_cluster_sg" {
  name        = "eks-cluster-${var.cluster_name}-sg"
  description = "Security group for EKS cluster ${var.cluster_name}"
  vpc_id      = data.aws_vpc.default.id

  # Allow inbound HTTPS from specified CIDR blocks
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    cidr_blocks     = var.allowed_cidr_blocks
    description     = "Allow HTTPS access to EKS API"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "eks-cluster-${var.cluster_name}-sg"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Get public subnets for cluster
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# EKS Cluster Provisioning
resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = data.aws_subnets.public.ids
    security_group_ids      = [aws_security_group.eks_cluster_sg.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.allowed_cidr_blocks
  }

  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/16"
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]

  tags = {
    Name        = var.cluster_name
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  lifecycle {
    ignore_changes = [version]
  }
}

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_group_role" {
  name = "eks-node-group-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })

  tags = {
    Name        = "eks-node-group-role"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Attach Required Policies to Node Group Role
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_node_group_role.name
}

# Create EKS Node Group
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids      = data.aws_subnets.public.ids
  version         = var.eks_version

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  instance_types = var.instance_types
  ami_type       = var.ami_type
  capacity_type  = "ON_DEMAND"
  disk_size      = var.disk_size

  remote_access {
    ec2_ssh_key = var.ssh_key_name
  }

  # Rolling update configuration for zero-downtime updates
  update_config {
    max_unavailable_percentage = 33
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
    aws_iam_role_policy_attachment.ssm_policy,
  ]

  tags = {
    Name        = var.node_group_name
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  lifecycle {
    ignore_changes = [version]
  }
}

# CloudWatch Log Group for EKS Logs
resource "aws_cloudwatch_log_group" "eks_logs" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "eks-logs-${var.cluster_name}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# OpenID Connect Provider for EKS
resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  url             = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer

  tags = {
    Name        = "eks-oidc-${var.cluster_name}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# IAM Role for AWS Load Balancer Controller
resource "aws_iam_role" "lb_controller_role" {
  name = "aws-load-balancer-controller-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks_oidc_provider.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks_oidc_provider.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "aws-load-balancer-controller"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Policy for AWS Load Balancer Controller
resource "aws_iam_role_policy_attachment" "lb_controller_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy"
  role       = aws_iam_role.lb_controller_role.name
}
