# ========================================
# FILE: main.tf (Fixed - Cycle Free)
# ========================================

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# ========================================
# AWS Provider
# ========================================
provider "aws" {
  region = var.aws_region
}

# ========================================
# VPC Module
# ========================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs              = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets  = var.private_subnet_cidrs
  public_subnets   = var.public_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}

# ========================================
# EKS Module (with IRSA)
# ========================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  enable_irsa = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  eks_managed_node_groups = {
    general = {
      name           = "${var.cluster_name}-node-group"
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 5
      desired_size = 3
      disk_size    = 20

       iam_role_name            = "eks-ng-general-role"
    iam_role_use_name_prefix = false
    }
  }

  cluster_security_group_additional_rules = {
    egress_all = {
      description = "Cluster all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = var.tags
}

# ========================================
# EKS Cluster Data Sources (AFTER creation)
# ========================================
data "aws_eks_cluster" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# ========================================
# Providers for Kubernetes & Helm (Alias)
# ========================================
provider "kubernetes" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  alias = "eks"
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# ========================================
# KMS Key for Vault Auto-Unseal
# ========================================
resource "aws_kms_key" "vault_unseal" {
  description             = "KMS key for Vault auto-unseal"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vault-unseal-key"
  })
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# ========================================
# RDS PostgreSQL Instance
# ========================================
resource "aws_db_subnet_group" "rds" {
  name       = "${var.cluster_name}-rds-subnet-group"
  subnet_ids = module.vpc.database_subnets
  tags = merge(var.tags, { Name = "${var.cluster_name}-rds-subnet-group" })
}

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-rds-sg" })
}

resource "random_password" "rds_password" {
  length  = 32
  special = true
}

resource "aws_db_instance" "postgresql" {
  identifier              = "${var.cluster_name}-postgresql"
  engine                  = "postgres"
  engine_version          = "15.4"
  instance_class          = "db.t3.micro" 
  allocated_storage       = 20
  max_allocated_storage   = 50
  storage_type            = "gp3"
  storage_encrypted       = true
  db_name                 = "microservices"
  username                = "vaultadmin"
  password                = random_password.rds_password.result
  db_subnet_group_name    = aws_db_subnet_group.rds.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = merge(var.tags, { Name = "${var.cluster_name}-postgresql" })
}

# ========================================
# IRSA for Vault (KMS Access)
# ========================================
module "vault_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-vault-kms-unseal"

  role_policy_arns = {
    kms = aws_iam_policy.vault_kms_unseal.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["vault:vault"]
    }
  }

  tags = var.tags
}

resource "aws_iam_policy" "vault_kms_unseal" {
  name        = "${var.cluster_name}-vault-kms-unseal-policy"
  description = "Policy for Vault to use KMS for auto-unseal"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.vault_unseal.arn
      }
    ]
  })

  tags = var.tags
}

# ========================================
# Kubernetes Namespace + SA for Vault
# ========================================
resource "kubernetes_namespace" "vault" {
  provider = kubernetes.eks
  metadata { name = "vault" }
  depends_on = [module.eks]
}

resource "kubernetes_service_account" "vault" {
  provider = kubernetes.eks
  metadata {
    name      = "vault"
    namespace = "vault"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.vault_irsa.iam_role_arn
    }
  }
  depends_on = [kubernetes_namespace.vault]
}

# ========================================
# Helm Release - HashiCorp Vault
# ========================================
resource "helm_release" "vault" {
  provider   = helm.eks
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.27.0"
  namespace  = kubernetes_namespace.vault.metadata[0].name

  values = [templatefile("${path.module}/vault-values.yaml", {
    kms_key_id           = aws_kms_key.vault_unseal.id
    aws_region           = var.aws_region
    service_account_name = "vault"
  })]

  depends_on = [
    module.eks,
    kubernetes_namespace.vault,
    kubernetes_service_account.vault
  ]
}

