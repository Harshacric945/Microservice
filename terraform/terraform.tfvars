# ========================================
# FILE 4: terraform/terraform.tfvars
# ========================================
# Customize these values for your setup

aws_region      = "ap-south-1"
cluster_name    =  "micro-eks"
cluster_version = "1.28"

tags = {
  Environment = "production"
  Project     = "microservices-ecommerce"
  Owner       = "harshakoppu945"
  ManagedBy   = "terraform"
}
