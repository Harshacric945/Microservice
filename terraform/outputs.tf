# ========================================
# FILE 3: terraform/outputs.tf
# ========================================

output "cluster_name" {
  description = "EKS Cluster Name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS Cluster Endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_region" {
  description = "AWS Region"
  value       = var.aws_region
}

output "oidc_provider_arn" {
  description = "OIDC Provider ARN (for IRSA)"
  value       = module.eks.oidc_provider_arn
}

output "rds_endpoint" {
  description = "RDS PostgreSQL Endpoint"
  value       = aws_db_instance.postgresql.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL Address (without port)"
  value       = aws_db_instance.postgresql.address
}

output "rds_username" {
  description = "RDS Admin Username"
  value       = aws_db_instance.postgresql.username
  sensitive   = true
}

output "rds_password" {
  description = "RDS Admin Password"
  value       = random_password.rds_password.result
  sensitive   = true
}

# ========================================
# COMMENT OUT: KMS outputs (resource doesn't exist)
# ========================================
# output "kms_key_id" {
#   description = "KMS Key ID for Vault"
#   value       = aws_kms_key.vault_unseal.id
# }

# output "vault_irsa_role_arn" {
#   description = "IAM Role ARN for Vault IRSA"
#   value       = module.vault_irsa.iam_role_arn
# }

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
