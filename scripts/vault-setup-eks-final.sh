#!/bin/bash
# ========================================
# VAULT SETUP - MANUAL SHAMIR (EKS)
# Final production-ready version
# ========================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VAULT SETUP - MANUAL SHAMIR (EKS)${NC}"
echo -e "${BLUE}========================================${NC}"

# ========================================
# Prerequisites
# ========================================
command -v jq >/dev/null || { echo -e "${RED}jq is required${NC}"; exit 1; }
command -v kubectl >/dev/null || { echo -e "${RED}kubectl is required${NC}"; exit 1; }
command -v aws >/dev/null || { echo -e "${RED}aws CLI is required${NC}"; exit 1; }

if ! command -v psql >/dev/null; then
  echo -e "${YELLOW}⚠ psql not found. DB creation steps will be skipped.${NC}"
fi

# ========================================
# Terraform Outputs
# ========================================
echo -e "${YELLOW}Retrieving Terraform outputs...${NC}"
TERRAFORM_DIR="../terraform"

RDS_ENDPOINT=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_endpoint 2>/dev/null | cut -d':' -f1 || true)
RDS_USERNAME=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_username 2>/dev/null || true)
RDS_PASSWORD=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_password 2>/dev/null || true)
CLUSTER_NAME=$(terraform -chdir=${TERRAFORM_DIR} output -raw cluster_name 2>/dev/null || true)
AWS_REGION=$(terraform -chdir=${TERRAFORM_DIR} output -raw aws_region 2>/dev/null || echo "ap-south-1")

if [ -z "${RDS_ENDPOINT}" ] || [ -z "${CLUSTER_NAME}" ]; then
    echo -e "${RED}Failed to retrieve required Terraform outputs.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ RDS Endpoint: ${RDS_ENDPOINT}${NC}"
echo -e "${GREEN}✓ Cluster: ${CLUSTER_NAME}${NC}"

# ========================================
# Update Kubeconfig
# ========================================
echo -e "${YELLOW}Updating kubeconfig...${NC}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null

# ========================================
# Wait for vault-0 (Running, not Ready!)
# ========================================
echo -e "${YELLOW}Step 1: Waiting for vault-0 to be Running...${NC}"
echo -e "${YELLOW}(Pod will show 0/1 until unsealed - this is normal)${NC}"

MAX_WAIT=300
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    POD_PHASE=$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$POD_PHASE" = "Running" ]; then
        echo -e "${GREEN}✓ vault-0 is Running${NC}"
        break
    fi
    
    echo -e "${YELLOW}  Pod status: $POD_PHASE ($ELAPSED/$MAX_WAIT seconds)${NC}"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$POD_PHASE" != "Running" ]; then
    echo -e "${RED}ERROR: vault-0 did not start${NC}"
    kubectl describe pod vault-0 -n vault
    exit 1
fi

# Give Vault process time to start
echo -e "${YELLOW}Waiting for Vault process to initialize (20 seconds)...${NC}"
sleep 20

# ========================================
# Check Initialization Status
# ========================================
echo -e "${YELLOW}Step 2: Checking Vault initialization status...${NC}"

STATUS_JSON=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo "{}")
INITIALIZED=$(echo "$STATUS_JSON" | jq -r '.initialized // false')
SEALED=$(echo "$STATUS_JSON" | jq -r '.sealed // true')

echo -e "${BLUE}Detected: Initialized=$INITIALIZED, Sealed=$SEALED${NC}"

ROOT_TOKEN=""

# ========================================
# Initialize or Load Existing
# ========================================
if [ "$INITIALIZED" = "true" ]; then
    echo -e "${GREEN}Step 3: Vault already initialized${NC}"
    
    if [ "$SEALED" = "true" ]; then
        echo -e "${RED}ERROR: Vault is SEALED${NC}"
        echo -e "${YELLOW}Please unseal manually:${NC}"
        echo "  kubectl exec -n vault -it vault-0 -- vault operator unseal"
        echo "  (Enter 3 keys when prompted)"
        exit 1
    fi
    
    if [ -f "vault-init-keys.json" ]; then
        ROOT_TOKEN=$(jq -r '.root_token' vault-init-keys.json)
        echo -e "${GREEN}✓ Token loaded from vault-init-keys.json${NC}"
    else
        echo -e "${YELLOW}Enter your root token:${NC}"
        read -s ROOT_TOKEN
    fi
else
    # Initialize Vault
    echo -e "${BLUE}Step 3: Initializing Vault with Shamir keys...${NC}"
    
    INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json)
    
    echo "$INIT_OUTPUT" > vault-init-keys.json
    chmod 600 vault-init-keys.json
    
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
    KEY1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
    KEY2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
    KEY3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
    
    echo -e "${GREEN}✓ Vault initialized!${NC}"
    echo -e "${GREEN}Root Token: ${ROOT_TOKEN}${NC}"
    echo -e "${RED}KEYS SAVED TO: vault-init-keys.json - BACKUP NOW!${NC}"
    
    # Unseal vault-0
    echo -e "${YELLOW}Step 4: Unsealing vault-0...${NC}"
    kubectl exec -n vault vault-0 -- vault operator unseal "${KEY1}" >/dev/null
    echo "  ✓ Key 1/3"
    kubectl exec -n vault vault-0 -- vault operator unseal "${KEY2}" >/dev/null
    echo "  ✓ Key 2/3"
    kubectl exec -n vault vault-0 -- vault operator unseal "${KEY3}" >/dev/null
    echo "  ✓ Key 3/3"
    echo -e "${GREEN}✓ vault-0 unsealed${NC}"
    
    # Wait for cluster stabilization
    echo -e "${YELLOW}Waiting for cluster to stabilize (30 seconds)...${NC}"
    sleep 30
    
    # Join and unseal vault-1
    echo -e "${YELLOW}Step 5: Processing vault-1...${NC}"
    POD1_PHASE=$(kubectl get pod vault-1 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$POD1_PHASE" = "Running" ]; then
        echo "  Joining vault-1 to cluster..."
        kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || echo "  Join may have already occurred"
        
        echo "  Unsealing vault-1..."
        kubectl exec -n vault vault-1 -- vault operator unseal "${KEY1}" >/dev/null || true
        kubectl exec -n vault vault-1 -- vault operator unseal "${KEY2}" >/dev/null || true
        kubectl exec -n vault vault-1 -- vault operator unseal "${KEY3}" >/dev/null || true
        echo -e "${GREEN}✓ vault-1 processed${NC}"
    else
        echo -e "${YELLOW}⚠ vault-1 not Running (status: $POD1_PHASE), skipping${NC}"
    fi
    
    # Join and unseal vault-2
    echo -e "${YELLOW}Step 6: Processing vault-2...${NC}"
    POD2_PHASE=$(kubectl get pod vault-2 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$POD2_PHASE" = "Running" ]; then
        echo "  Joining vault-2 to cluster..."
        kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || echo "  Join may have already occurred"
        
        echo "  Unsealing vault-2..."
        kubectl exec -n vault vault-2 -- vault operator unseal "${KEY1}" >/dev/null || true
        kubectl exec -n vault vault-2 -- vault operator unseal "${KEY2}" >/dev/null || true
        kubectl exec -n vault vault-2 -- vault operator unseal "${KEY3}" >/dev/null || true
        echo -e "${GREEN}✓ vault-2 processed${NC}"
    else
        echo -e "${YELLOW}⚠ vault-2 not Running (status: $POD2_PHASE), skipping${NC}"
    fi
fi

export VAULT_TOKEN="${ROOT_TOKEN}"

# ========================================
# Cluster Status
# ========================================
echo ""
echo -e "${BLUE}Vault Cluster Status:${NC}"
kubectl get pods -n vault
echo ""
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault operator raft list-peers 2>/dev/null || echo "Raft status unavailable"

# ========================================
# Database Secrets Engine
# ========================================
echo ""
echo -e "${YELLOW}Step 7: Configuring database secrets engine...${NC}"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault secrets enable database 2>/dev/null || echo "  Already enabled"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write database/config/postgresql \
    plugin_name=postgresql-database-plugin \
    allowed_roles="cartservice-role,checkoutservice-role,productcatalogservice-role,paymentservice-role" \
    connection_url="postgresql://{{username}}:{{password}}@${RDS_ENDPOINT}:5432/postgres?sslmode=require" \
    username="${RDS_USERNAME}" \
    password="${RDS_PASSWORD}"

echo -e "${GREEN}✓ Database engine configured${NC}"

# ========================================
# Create Databases (if psql available)
# ========================================
if command -v psql >/dev/null; then
    echo -e "${YELLOW}Step 8: Creating databases...${NC}"
    export PGPASSWORD="${RDS_PASSWORD}"
    
    for db in cart_db checkout_db product_db payment_db; do
        psql -h "${RDS_ENDPOINT}" -U "${RDS_USERNAME}" -d postgres -c "CREATE DATABASE ${db};" 2>/dev/null \
            && echo "  ✓ ${db}" || echo "  ✓ ${db} (already exists)"
    done
else
    echo -e "${YELLOW}Step 8: Skipping DB creation (psql not installed)${NC}"
fi

# ========================================
# Vault Database Roles
# ========================================
echo -e "${YELLOW}Step 9: Creating Vault database roles...${NC}"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write database/roles/cartservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE cart_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ cartservice-role"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write database/roles/checkoutservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE checkout_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ checkoutservice-role"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write database/roles/productcatalogservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE product_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ productcatalogservice-role"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write database/roles/paymentservice-role \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE payment_db TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
echo "  ✓ paymentservice-role"

echo -e "${GREEN}✓ All database roles created${NC}"

# ========================================
# Kubernetes Auth
# ========================================
echo -e "${YELLOW}Step 10: Configuring Kubernetes authentication...${NC}"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault auth enable kubernetes 2>/dev/null || echo "  Already enabled"

# Get Kubernetes cluster info
KUBERNETES_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')
KUBERNETES_CA_CERT=$(kubectl get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' 2>/dev/null || \
    kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

# Get vault-auth SA token
REVIEWER_TOKEN=$(kubectl -n vault create token vault-auth 2>/dev/null || \
    kubectl get secret -n vault -l kubernetes.io/service-account.name=vault-auth -o jsonpath='{.items[0].data.token}' | base64 -d)

if [ -z "$REVIEWER_TOKEN" ]; then
    echo -e "${RED}ERROR: Could not get reviewer token from vault-auth SA${NC}"
    echo -e "${YELLOW}Make sure vault-kubernetes-auth-SETUP.yaml is applied${NC}"
    exit 1
fi

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write auth/kubernetes/config \
    kubernetes_host="${KUBERNETES_HOST}" \
    kubernetes_ca_cert="${KUBERNETES_CA_CERT}" \
    token_reviewer_jwt="${REVIEWER_TOKEN}"

echo -e "${GREEN}✓ Kubernetes auth configured${NC}"

# ========================================
# Policies
# ========================================
echo -e "${YELLOW}Step 11: Creating policies...${NC}"

for service in cartservice checkoutservice productcatalogservice paymentservice; do
    cat <<EOF | kubectl exec -i -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault policy write ${service}-policy -
path "database/creds/${service}-role" {
  capabilities = ["read"]
}
path "kv/data/${service}/*" {
  capabilities = ["read", "list"]
}
EOF
    echo "  ✓ ${service}-policy"
done

echo -e "${GREEN}✓ All policies created${NC}"

# ========================================
# Kubernetes Roles
# ========================================
echo -e "${YELLOW}Step 12: Creating Kubernetes roles in Vault...${NC}"

# Try with audience first (K8s 1.24+), fallback without it
for service in cartservice checkoutservice productcatalogservice paymentservice; do
    kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write auth/kubernetes/role/${service}-role \
        bound_service_account_names="${service}-sa" \
        bound_service_account_namespaces="default" \
        policies="${service}-policy" \
        ttl=1h \
        audience="vault" 2>/dev/null || \
    kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault write auth/kubernetes/role/${service}-role \
        bound_service_account_names="${service}-sa" \
        bound_service_account_namespaces="default" \
        policies="${service}-policy" \
        ttl=1h
    echo "  ✓ ${service}-role"
done

echo -e "${GREEN}✓ All Kubernetes roles created${NC}"

# ========================================
# KV Secrets Engine
# ========================================
echo -e "${YELLOW}Step 13: Enabling KV secrets engine...${NC}"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault secrets enable -path=kv kv-v2 2>/dev/null || echo "  Already enabled"

# Store sample secrets
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault kv put kv/cartservice/config \
    redis_host="redis.default.svc.cluster.local" \
    redis_port="6379" >/dev/null

echo -e "${GREEN}✓ KV engine enabled and sample secret stored${NC}"

# ========================================
# Test Credential Generation
# ========================================
echo -e "${YELLOW}Step 14: Testing dynamic credential generation...${NC}"
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${VAULT_TOKEN} vault read database/creds/cartservice-role || \
    echo -e "${YELLOW}⚠ If this fails, check DB connectivity and security groups${NC}"

# ========================================
# Final Summary
# ========================================
UI_HOST=$(kubectl get svc vault-ui -n vault -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓✓✓ VAULT SETUP COMPLETE! ✓✓✓${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Root Token:${NC} ${ROOT_TOKEN}"
echo -e "${YELLOW}Keys File:${NC} $(pwd)/vault-init-keys.json"

if [ -n "$UI_HOST" ]; then
    echo -e "${YELLOW}Vault UI:${NC} http://${UI_HOST}:8200"
else
    echo -e "${YELLOW}Vault UI:${NC} kubectl port-forward -n vault svc/vault-ui 8200:8200"
fi

echo ""
echo -e "${RED}CRITICAL: BACKUP vault-init-keys.json NOW!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Backup vault-init-keys.json to secure location"
echo "  2. Deploy microservices with ArgoCD"
echo "  3. Verify Vault Agent injection works"
echo ""
echo -e "${GREEN}========================================${NC}"
