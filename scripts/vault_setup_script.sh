#!/bin/bash
# ========================================
# COMPLETE VAULT SETUP - FINAL VERSION
# Includes Kubernetes Auth configuration fix
# Run AFTER applying vault-kubernetes-auth-SETUP.yaml
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}COMPLETE VAULT SETUP - FINAL${NC}"
echo -e "${BLUE}========================================${NC}"

# ========================================
# Verify Prerequisites
# ========================================
echo -e "${YELLOW}Verifying prerequisites...${NC}"

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Installing jq...${NC}"
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y jq >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install -y jq >/dev/null 2>&1
    fi
fi

# ========================================
# Get Terraform Outputs
# ========================================
echo -e "${YELLOW}Retrieving Terraform outputs...${NC}"

TERRAFORM_DIR="../terraform"

if [ ! -d "$TERRAFORM_DIR" ]; then
    echo -e "${RED}ERROR: Terraform directory not found at $TERRAFORM_DIR${NC}"
    exit 1
fi

RDS_ENDPOINT=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_endpoint 2>/dev/null | cut -d':' -f1)
RDS_USERNAME=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_username 2>/dev/null)
RDS_PASSWORD=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_password 2>/dev/null)
CLUSTER_NAME=$(terraform -chdir=${TERRAFORM_DIR} output -raw cluster_name 2>/dev/null)
AWS_REGION=$(terraform -chdir=${TERRAFORM_DIR} output -raw aws_region 2>/dev/null || echo "ap-south-1")

if [ -z "$RDS_ENDPOINT" ] || [ -z "$RDS_USERNAME" ] || [ -z "$RDS_PASSWORD" ]; then
    echo -e "${RED}Failed to retrieve Terraform outputs. Run 'terraform apply' first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ RDS Endpoint: ${RDS_ENDPOINT}${NC}"
echo -e "${GREEN}✓ Cluster: ${CLUSTER_NAME}${NC}"
echo ""

# ========================================
# Update Kubeconfig
# ========================================
echo -e "${YELLOW}Updating kubeconfig...${NC}"
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME} 2>/dev/null || true

# ========================================
# Wait for Vault Pods
# ========================================
echo -e "${YELLOW}Checking Vault pod status...${NC}"

VAULT_0_STATUS=$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

if [ "$VAULT_0_STATUS" != "Running" ]; then
    echo -e "${RED}Vault pods are not running. Status: $VAULT_0_STATUS${NC}"
    kubectl get pods -n vault
    exit 1
fi

echo -e "${GREEN}✓ Vault pods are running${NC}"
echo ""

# ========================================
# Port Forward
# ========================================
echo -e "${YELLOW}Setting up port-forward to Vault...${NC}"
kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 5

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_SKIP_VERIFY=true

echo -e "${GREEN}✓ Port-forward established${NC}"
echo ""

# ========================================
# Check Vault Initialization Status
# ========================================
echo -e "${YELLOW}Checking Vault initialization status...${NC}"

VAULT_STATUS=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized":false}')
IS_INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')

if [ "$IS_INITIALIZED" = "false" ]; then
    # ========================================
    # Initialize Vault
    # ========================================
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}INITIALIZING VAULT${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Initializing Vault with KMS auto-unseal...${NC}"
    echo ""

    INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
        -recovery-shares=5 \
        -recovery-threshold=3 \
        -format=json)

    echo "$INIT_OUTPUT" > vault-init-keys.json
    chmod 600 vault-init-keys.json

    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ VAULT INITIALIZED!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}ROOT TOKEN (save this):${NC}"
    echo -e "${YELLOW}${ROOT_TOKEN}${NC}"
    echo ""
    echo -e "${GREEN}Recovery Keys:${NC}"
    echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[]' | nl -v 1 -w 2 -s '. '
    echo ""
    echo -e "${RED}CRITICAL: Credentials saved to vault-init-keys.json${NC}"
    echo -e "${RED}BACKUP THIS FILE TO A SECURE LOCATION NOW!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    export VAULT_TOKEN=$ROOT_TOKEN

    # Wait for Vault to stabilize
    echo -e "${YELLOW}Waiting for Vault to stabilize...${NC}"
    sleep 10

    # Join Raft cluster
    echo -e "${YELLOW}Joining vault-1 and vault-2 to Raft cluster...${NC}"
    kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || echo "  vault-1 join (may already be member)"
    sleep 3
    kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || echo "  vault-2 join (may already be member)"
    sleep 5

    echo -e "${GREEN}✓ Raft cluster formed${NC}"
    echo ""

else
    echo -e "${GREEN}✓ Vault is already initialized${NC}"

    # Try to get token from file
    if [ -f "vault-init-keys.json" ]; then
        ROOT_TOKEN=$(cat vault-init-keys.json | jq -r '.root_token')
        echo -e "${GREEN}✓ Root token loaded from vault-init-keys.json${NC}"
    else
        echo -e "${YELLOW}Please enter your Vault root token:${NC}"
        read -s ROOT_TOKEN
        echo ""
    fi

    export VAULT_TOKEN=$ROOT_TOKEN

    # Verify token
    if ! kubectl exec -n vault vault-0 -- vault token lookup -format=json >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Invalid root token${NC}"
        kill $PORT_FORWARD_PID 2>/dev/null
        exit 1
    fi

    echo -e "${GREEN}✓ Root token validated${NC}"
    echo ""
fi

# ========================================
# Enable Database Secrets Engine
# ========================================
echo -e "${YELLOW}Enabling database secrets engine...${NC}"

kubectl exec -n vault vault-0 -- vault secrets enable database 2>/dev/null || echo "  Already enabled"
echo -e "${GREEN}✓ Database secrets engine enabled${NC}"
echo ""

# ========================================
# Configure PostgreSQL Connection
# ========================================
echo -e "${YELLOW}Configuring PostgreSQL connection...${NC}"

kubectl exec -n vault vault-0 -- vault write database/config/postgresql \
    plugin_name=postgresql-database-plugin \
    allowed_roles="cartservice-role,checkoutservice-role,productcatalogservice-role,paymentservice-role" \
    connection_url="postgresql://{{username}}:{{password}}@${RDS_ENDPOINT}:5432/postgres?sslmode=require" \
    username="${RDS_USERNAME}" \
    password="${RDS_PASSWORD}"

echo -e "${GREEN}✓ PostgreSQL connection configured${NC}"
echo ""

# ========================================
# Create Databases
# ========================================
echo -e "${YELLOW}Creating databases in PostgreSQL...${NC}"

export PGPASSWORD=${RDS_PASSWORD}

for db in cart_db checkout_db product_db payment_db; do
    psql -h ${RDS_ENDPOINT} -U ${RDS_USERNAME} -d postgres -c "CREATE DATABASE ${db};" 2>/dev/null && echo "  ✓ ${db}" || echo "  ✓ ${db} (already exists)"
done

echo -e "${GREEN}✓ All databases verified${NC}"
echo ""

# ========================================
# Create Vault Roles
# ========================================
echo -e "${YELLOW}Creating Vault database roles...${NC}"

kubectl exec -n vault vault-0 -- vault write database/roles/cartservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE cart_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ cartservice-role"

kubectl exec -n vault vault-0 -- vault write database/roles/checkoutservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE checkout_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ checkoutservice-role"

kubectl exec -n vault vault-0 -- vault write database/roles/productcatalogservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE product_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ productcatalogservice-role"

kubectl exec -n vault vault-0 -- vault write database/roles/paymentservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE payment_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ paymentservice-role"

echo -e "${GREEN}✓ All database roles created${NC}"
echo ""

# ========================================
# Enable Kubernetes Auth
# ========================================
echo -e "${YELLOW}Enabling Kubernetes authentication...${NC}"

kubectl exec -n vault vault-0 -- vault auth enable kubernetes 2>/dev/null || echo "  Already enabled"
echo -e "${GREEN}✓ Kubernetes auth enabled${NC}"
echo ""

# ========================================
# Configure Kubernetes Auth - CORRECTED METHOD
# ========================================
echo -e "${YELLOW}Configuring Kubernetes auth (with vault-auth ServiceAccount)...${NC}"

# Get Kubernetes cluster host
KUBERNETES_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')

# Get CA certificate from kube-system
KUBERNETES_CA_CERT=$(kubectl get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')

# Get token from vault-auth ServiceAccount
# This method works on all Kubernetes versions
echo -e "${YELLOW}Retrieving vault-auth ServiceAccount token...${NC}"

# Wait for vault-auth secret to be created
MAX_RETRIES=30
RETRY_COUNT=0
VAULT_AUTH_SECRET=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    VAULT_AUTH_SECRET=$(kubectl get secret -n vault -l kubernetes.io/service-account.name=vault-auth -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$VAULT_AUTH_SECRET" ]; then
        echo -e "${GREEN}✓ Found vault-auth secret: $VAULT_AUTH_SECRET${NC}"
        break
    fi
    echo -e "${YELLOW}  Waiting for vault-auth secret... ($RETRY_COUNT/$MAX_RETRIES)${NC}"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -z "$VAULT_AUTH_SECRET" ]; then
    echo -e "${RED}ERROR: Could not find vault-auth ServiceAccount secret${NC}"
    echo -e "${YELLOW}Make sure vault-kubernetes-auth-SETUP.yaml was applied:${NC}"
    echo "  kubectl apply -f vault-kubernetes-auth-SETUP.yaml"
    kill $PORT_FORWARD_PID 2>/dev/null
    exit 1
fi

REVIEWER_TOKEN=$(kubectl get secret -n vault $VAULT_AUTH_SECRET -o jsonpath='{.data.token}' | base64 -d)

# Configure Kubernetes auth method
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host="${KUBERNETES_HOST}" \
    kubernetes_ca_cert="${KUBERNETES_CA_CERT}" \
    token_reviewer_jwt="${REVIEWER_TOKEN}"

echo -e "${GREEN}✓ Kubernetes auth configured with vault-auth token${NC}"
echo ""

# ========================================
# Create Policies
# ========================================
echo -e "${YELLOW}Creating Vault policies...${NC}"

for service in cartservice checkoutservice productcatalogservice paymentservice; do
    kubectl exec -n vault vault-0 -- vault policy write ${service}-policy - <<EOF
path "database/creds/${service}-role" {
  capabilities = ["read"]
}
EOF
    echo "  ✓ ${service}-policy"
done

echo -e "${GREEN}✓ All policies created${NC}"
echo ""

# ========================================
# Create Kubernetes Roles in Vault
# ========================================
echo -e "${YELLOW}Creating Kubernetes roles in Vault...${NC}"

for service in cartservice checkoutservice productcatalogservice paymentservice; do
    kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/${service}-role \
        bound_service_account_names="${service}-sa" \
        bound_service_account_namespaces="default" \
        policies="${service}-policy" \
        ttl=1h
    echo "  ✓ ${service}-role"
done

echo -e "${GREEN}✓ All Kubernetes roles created${NC}"
echo ""

# ========================================
# Test Dynamic Credentials
# ========================================
echo -e "${YELLOW}Testing dynamic credential generation...${NC}"
echo ""

kubectl exec -n vault vault-0 -- vault read database/creds/cartservice-role

echo ""

# ========================================
# Get Access Info
# ========================================
VAULT_UI_LB=$(kubectl get svc -n vault vault-ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "LoadBalancer pending...")

# ========================================
# Cleanup
# ========================================
kill $PORT_FORWARD_PID 2>/dev/null || true

# ========================================
# Final Summary
# ========================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓✓✓ VAULT SETUP COMPLETE! ✓✓✓${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}YOUR ROOT TOKEN:${NC}"
echo -e "${GREEN}${ROOT_TOKEN}${NC}"
echo ""
echo -e "${YELLOW}Credentials saved to:${NC}"
echo "  $(pwd)/vault-init-keys.json"
echo ""
echo -e "${YELLOW}Vault UI Access:${NC}"
echo "  URL: http://${VAULT_UI_LB}:8200"
echo "  Login with root token above"
echo ""
echo -e "${YELLOW}Database Information:${NC}"
echo "  Endpoint: ${RDS_ENDPOINT}"
echo "  Databases: cart_db, checkout_db, product_db, payment_db"
echo ""
echo -e "${YELLOW}Kubernetes Auth is configured with:${NC}"
echo "  - vault-auth ServiceAccount (has system:auth-delegator)"
echo "  - Policies: cartservice-policy, checkoutservice-policy, etc."
echo "  - Roles bound to: cartservice-sa, checkoutservice-sa, etc."
echo ""
echo -e "${RED}NEXT STEPS:${NC}"
echo "  1. BACKUP vault-init-keys.json to 1Password/AWS Secrets Manager"
echo "  2. DELETE vault-init-keys.json from this server"
echo "  3. Deploy microservices (they have their own SAs in vault-kubernetes-auth-SETUP.yaml)"
echo ""
echo -e "${GREEN}All services configured for dynamic credentials!${NC}"
echo -e "${GREEN}========================================${NC}"