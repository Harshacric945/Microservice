#!/bin/bash
# ========================================
# Vault Post-Deployment Configuration Script
# Run this AFTER Terraform completes
# ========================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Vault Configuration Script${NC}"
echo -e "${GREEN}========================================${NC}"

# ========================================
# Prerequisites Check
# ========================================
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

if ! command -v vault &> /dev/null; then
    echo -e "${RED}vault CLI not found. Installing...${NC}"
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update && sudo apt install vault
fi

# ========================================
# Get Terraform Outputs
# ========================================
echo -e "${YELLOW}Retrieving Terraform outputs...${NC}"

RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d':' -f1)
RDS_USERNAME=$(terraform output -raw rds_username)
RDS_PASSWORD=$(terraform output -raw rds_password)
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "ap-south-1")

echo -e "${GREEN}✓ RDS Endpoint: ${RDS_ENDPOINT}${NC}"
echo -e "${GREEN}✓ Cluster: ${CLUSTER_NAME}${NC}"

# ========================================
# Update Kubeconfig
# ========================================
echo -e "${YELLOW}Updating kubeconfig...${NC}"
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

# ========================================
# Wait for Vault Pods
# ========================================
echo -e "${YELLOW}Waiting for Vault pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

# ========================================
# Port Forward Vault
# ========================================
echo -e "${YELLOW}Setting up port-forward to Vault...${NC}"
kubectl port-forward -n vault svc/vault 8200:8200 &
PORT_FORWARD_PID=$!
sleep 5

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_SKIP_VERIFY=true

# ========================================
# Initialize Vault (ONE TIME ONLY)
# ========================================
echo -e "${YELLOW}Checking Vault initialization status...${NC}"

if vault status 2>&1 | grep -q "Vault is not initialized"; then
    echo -e "${GREEN}Initializing Vault...${NC}"
    
    INIT_OUTPUT=$(vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json)
    
    # Save init output securely
    echo "${INIT_OUTPUT}" > vault-init-keys.json
    chmod 600 vault-init-keys.json
    
    ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}CRITICAL: SAVE THESE CREDENTIALS!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${YELLOW}Root Token: ${ROOT_TOKEN}${NC}"
    echo -e "${YELLOW}Recovery Keys saved to: vault-init-keys.json${NC}"
    echo -e "${RED}STORE THIS FILE SECURELY AND DELETE FROM THIS SERVER!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    export VAULT_TOKEN=${ROOT_TOKEN}
    
    # Vault should auto-unseal via KMS
    echo -e "${GREEN}Vault initialized and auto-unsealed via AWS KMS${NC}"
else
    echo -e "${GREEN}Vault already initialized${NC}"
    echo -e "${YELLOW}Please enter your root token:${NC}"
    read -s ROOT_TOKEN
    export VAULT_TOKEN=${ROOT_TOKEN}
fi

# Verify Vault is unsealed
if ! vault status | grep -q "Sealed.*false"; then
    echo -e "${RED}ERROR: Vault is sealed. Check KMS permissions.${NC}"
    exit 1
fi

# ========================================
# Enable Database Secrets Engine
# ========================================
echo -e "${YELLOW}Enabling database secrets engine...${NC}"

if vault secrets list | grep -q "^database/"; then
    echo -e "${GREEN}Database secrets engine already enabled${NC}"
else
    vault secrets enable database
    echo -e "${GREEN}✓ Database secrets engine enabled${NC}"
fi

# ========================================
# Configure PostgreSQL Connection
# ========================================
echo -e "${YELLOW}Configuring PostgreSQL connection in Vault...${NC}"

vault write database/config/postgresql \
    plugin_name=postgresql-database-plugin \
    allowed_roles="cartservice-role,checkoutservice-role,productcatalogservice-role,paymentservice-role" \
    connection_url="postgresql://{{username}}:{{password}}@${RDS_ENDPOINT}:5432/postgres?sslmode=require" \
    username="${RDS_USERNAME}" \
    password="${RDS_PASSWORD}"

echo -e "${GREEN}✓ PostgreSQL connection configured${NC}"

# ========================================
# Create Databases in PostgreSQL
# ========================================
echo -e "${YELLOW}Creating databases in PostgreSQL...${NC}"

PGPASSWORD=${RDS_PASSWORD} psql -h ${RDS_ENDPOINT} -U ${RDS_USERNAME} -d postgres -c "CREATE DATABASE cart_db;" 2>/dev/null || echo "cart_db exists"
PGPASSWORD=${RDS_PASSWORD} psql -h ${RDS_ENDPOINT} -U ${RDS_USERNAME} -d postgres -c "CREATE DATABASE checkout_db;" 2>/dev/null || echo "checkout_db exists"
PGPASSWORD=${RDS_PASSWORD} psql -h ${RDS_ENDPOINT} -U ${RDS_USERNAME} -d postgres -c "CREATE DATABASE product_db;" 2>/dev/null || echo "product_db exists"
PGPASSWORD=${RDS_PASSWORD} psql -h ${RDS_ENDPOINT} -U ${RDS_USERNAME} -d postgres -c "CREATE DATABASE payment_db;" 2>/dev/null || echo "payment_db exists"

echo -e "${GREEN}✓ Databases created${NC}"

# ========================================
# Create Vault Roles for Each Service
# ========================================
echo -e "${YELLOW}Creating Vault database roles...${NC}"

# Cart Service Role
vault write database/roles/cartservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT ALL PRIVILEGES ON DATABASE cart_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

# Checkout Service Role
vault write database/roles/checkoutservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT ALL PRIVILEGES ON DATABASE checkout_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

# Product Catalog Service Role
vault write database/roles/productcatalogservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT ALL PRIVILEGES ON DATABASE product_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

# Payment Service Role
vault write database/roles/paymentservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT ALL PRIVILEGES ON DATABASE payment_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

echo -e "${GREEN}✓ All Vault database roles created${NC}"

# ========================================
# Enable Kubernetes Auth
# ========================================
echo -e "${YELLOW}Enabling Kubernetes authentication...${NC}"

if vault auth list | grep -q "^kubernetes/"; then
    echo -e "${GREEN}Kubernetes auth already enabled${NC}"
else
    vault auth enable kubernetes
    echo -e "${GREEN}✓ Kubernetes auth enabled${NC}"
fi

# ========================================
# Configure Kubernetes Auth
# ========================================
echo -e "${YELLOW}Configuring Kubernetes auth method...${NC}"

KUBERNETES_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')

vault write auth/kubernetes/config \
    kubernetes_host="${KUBERNETES_HOST}" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || \
vault write auth/kubernetes/config \
    kubernetes_host="${KUBERNETES_HOST}"

echo -e "${GREEN}✓ Kubernetes auth configured${NC}"

# ========================================
# Create Vault Policies
# ========================================
echo -e "${YELLOW}Creating Vault policies...${NC}"

for service in cartservice checkoutservice productcatalogservice paymentservice; do
    vault policy write ${service}-policy - <<EOF
path "database/creds/${service}-role" {
  capabilities = ["read"]
}
EOF
    echo -e "${GREEN}✓ Policy created: ${service}-policy${NC}"
done

# ========================================
# Create Kubernetes Roles in Vault
# ========================================
echo -e "${YELLOW}Creating Kubernetes roles in Vault...${NC}"

for service in cartservice checkoutservice productcatalogservice paymentservice; do
    vault write auth/kubernetes/role/${service}-role \
        bound_service_account_names="${service}-sa" \
        bound_service_account_namespaces="default" \
        policies="${service}-policy" \
        ttl=1h
    echo -e "${GREEN}✓ K8s role created: ${service}-role${NC}"
done

# ========================================
# Test Dynamic Credentials
# ========================================
echo -e "${YELLOW}Testing dynamic credential generation...${NC}"

echo -e "${YELLOW}Testing cartservice credentials:${NC}"
vault read database/creds/cartservice-role

# ========================================
# Cleanup
# ========================================
kill $PORT_FORWARD_PID 2>/dev/null

# ========================================
# Summary
# ========================================
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Vault Configuration Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Save vault-init-keys.json to a secure location"
echo "2. Delete vault-init-keys.json from this server"
echo "3. Deploy microservices using ArgoCD"
echo "4. Access Vault UI:"
echo "   kubectl port-forward -n vault svc/vault-ui 8200:8200"
echo "   Open: http://localhost:8200"
echo "   Login with root token"
echo ""
echo -e "${YELLOW}RDS Endpoint: ${RDS_ENDPOINT}${NC}"
echo -e "${YELLOW}Vault Address: ${VAULT_ADDR}${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"