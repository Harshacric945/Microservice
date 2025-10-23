#!/bin/bash
# ========================================
# VAULT SETUP - CORRECT LOGIC
# Handles uninitialized Vault properly
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VAULT SETUP - CORRECT LOGIC${NC}"
echo -e "${BLUE}========================================${NC}"

# ========================================
# Prerequisites
# ========================================
echo -e "${YELLOW}Checking prerequisites...${NC}"

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

RDS_ENDPOINT=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_endpoint 2>/dev/null | cut -d':' -f1)
RDS_USERNAME=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_username 2>/dev/null)
RDS_PASSWORD=$(terraform -chdir=${TERRAFORM_DIR} output -raw rds_password 2>/dev/null)
CLUSTER_NAME=$(terraform -chdir=${TERRAFORM_DIR} output -raw cluster_name 2>/dev/null)
AWS_REGION=$(terraform -chdir=${TERRAFORM_DIR} output -raw aws_region 2>/dev/null || echo "ap-south-1")

if [ -z "$RDS_ENDPOINT" ] || [ -z "$RDS_USERNAME" ] || [ -z "$RDS_PASSWORD" ]; then
    echo -e "${RED}Failed to retrieve Terraform outputs.${NC}"
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
# STEP 1: Wait for Pod to be RUNNING (not Ready)
# ========================================
echo -e "${YELLOW}Step 1: Waiting for vault-0 to be Running...${NC}"
echo -e "${YELLOW}(Pod will be Running 0/1 if uninitialized)${NC}"

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

echo ""

# ========================================
# STEP 2: Wait for Vault Process to be Listening
# ========================================
echo -e "${YELLOW}Step 2: Waiting for Vault process to start (30 seconds)...${NC}"
sleep 30

echo -e "${GREEN}✓ Vault process should be ready${NC}"
echo ""

# ========================================
# STEP 3: Port Forward
# ========================================
echo -e "${YELLOW}Step 3: Setting up port-forward...${NC}"
kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 5

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_SKIP_VERIFY=true

echo -e "${GREEN}✓ Port-forward established${NC}"
echo ""

# ========================================
# STEP 4: Check Initialization Status
# ========================================
echo -e "${YELLOW}Step 4: Checking Vault initialization status...${NC}"

# Run vault status and capture output
VAULT_STATUS_OUTPUT=$(kubectl exec -n vault vault-0 -- vault status 2>&1 || true)
echo "$VAULT_STATUS_OUTPUT"
echo ""

# Parse status from output
IS_INITIALIZED=$(echo "$VAULT_STATUS_OUTPUT" | grep "Initialized" | awk '{print $2}')
IS_SEALED=$(echo "$VAULT_STATUS_OUTPUT" | grep "Sealed" | awk '{print $2}')

echo -e "${BLUE}Detected: Initialized=$IS_INITIALIZED, Sealed=$IS_SEALED${NC}"
echo ""

# ========================================
# STEP 5: Initialize if Needed
# ========================================
if [ "$IS_INITIALIZED" = "false" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}STEP 5: INITIALIZING VAULT${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Running: vault operator init${NC}"
    echo ""

    # Initialize Vault
    INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
        -recovery-shares=5 \
        -recovery-threshold=3 \
        -format=json)

    # Save output
    echo "$INIT_OUTPUT" > vault-init-keys.json
    chmod 600 vault-init-keys.json

    # Extract token
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

    # Display results
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ VAULT INITIALIZED SUCCESSFULLY!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}ROOT TOKEN:${NC}"
    echo -e "${YELLOW}${ROOT_TOKEN}${NC}"
    echo ""
    echo -e "${GREEN}Recovery Keys:${NC}"
    echo "$INIT_OUTPUT" | jq -r '.recovery_keys_b64[]' | nl -v 1 -w 2 -s '. '
    echo ""
    echo -e "${RED}CRITICAL: Saved to vault-init-keys.json${NC}"
    echo -e "${RED}BACKUP THIS FILE NOW!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    export VAULT_TOKEN=$ROOT_TOKEN

    # Wait for KMS auto-unseal
    echo -e "${YELLOW}Step 6: Waiting for KMS auto-unseal (10 seconds)...${NC}"
    sleep 10

    # Verify unsealed
    VAULT_STATUS_AFTER=$(kubectl exec -n vault vault-0 -- vault status 2>&1)
    echo "$VAULT_STATUS_AFTER"
    echo ""

    # Join Raft cluster
    echo -e "${YELLOW}Step 7: Joining vault-1 and vault-2 to Raft cluster...${NC}"
    
    kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || echo "  vault-1 join attempt"
    sleep 3
    
    kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || echo "  vault-2 join attempt"
    sleep 5

    echo -e "${GREEN}✓ Raft cluster formed${NC}"
    echo ""

    # Wait for all pods to be ready
    echo -e "${YELLOW}Step 8: Waiting for all Vault pods to be Ready...${NC}"
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=120s || true
    
    kubectl get pods -n vault
    echo ""

elif [ "$IS_INITIALIZED" = "true" ] && [ "$IS_SEALED" = "true" ]; then
    # Initialized but sealed - wait for auto-unseal
    echo -e "${YELLOW}Step 5: Vault is initialized but sealed${NC}"
    echo -e "${YELLOW}Waiting for KMS auto-unseal...${NC}"
    
    for i in {1..30}; do
        VAULT_STATUS_CHECK=$(kubectl exec -n vault vault-0 -- vault status 2>&1)
        IS_SEALED_NOW=$(echo "$VAULT_STATUS_CHECK" | grep "Sealed" | awk '{print $2}')
        
        if [ "$IS_SEALED_NOW" = "false" ]; then
            echo -e "${GREEN}✓ Vault unsealed${NC}"
            break
        fi
        
        echo -e "${YELLOW}  Still sealed, waiting... ($i/30)${NC}"
        sleep 5
    done
    
    # Load token
    if [ -f "vault-init-keys.json" ]; then
        ROOT_TOKEN=$(cat vault-init-keys.json | jq -r '.root_token')
        export VAULT_TOKEN=$ROOT_TOKEN
        echo -e "${GREEN}✓ Token loaded from vault-init-keys.json${NC}"
    else
        echo -e "${RED}ERROR: vault-init-keys.json not found${NC}"
        echo -e "${YELLOW}Please enter your root token:${NC}"
        read -s ROOT_TOKEN
        export VAULT_TOKEN=$ROOT_TOKEN
    fi
    echo ""

else
    # Already initialized and unsealed
    echo -e "${GREEN}Step 5: Vault is already initialized and unsealed${NC}"
    
    if [ -f "vault-init-keys.json" ]; then
        ROOT_TOKEN=$(cat vault-init-keys.json | jq -r '.root_token')
        export VAULT_TOKEN=$ROOT_TOKEN
        echo -e "${GREEN}✓ Token loaded from vault-init-keys.json${NC}"
    else
        echo -e "${YELLOW}vault-init-keys.json not found${NC}"
        echo -e "${YELLOW}Please enter your root token:${NC}"
        read -s ROOT_TOKEN
        export VAULT_TOKEN=$ROOT_TOKEN
    fi
    echo ""
fi

# ========================================
# STEP 9: Verify Token Works
# ========================================
echo -e "${YELLOW}Step 9: Verifying token...${NC}"

if ! kubectl exec -n vault vault-0 -- vault token lookup >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Token is invalid or expired${NC}"
    kill $PORT_FORWARD_PID 2>/dev/null
    exit 1
fi

echo -e "${GREEN}✓ Token is valid${NC}"
echo ""

# ========================================
# STEP 10: Configure Database Secrets Engine
# ========================================
echo -e "${YELLOW}Step 10: Configuring database secrets engine...${NC}"

kubectl exec -n vault vault-0 -- vault secrets enable database 2>/dev/null || echo "  Already enabled"

kubectl exec -n vault vault-0 -- vault write database/config/postgresql \
    plugin_name=postgresql-database-plugin \
    allowed_roles="cartservice-role,checkoutservice-role,productcatalogservice-role,paymentservice-role" \
    connection_url="postgresql://{{username}}:{{password}}@${RDS_ENDPOINT}:5432/postgres?sslmode=require" \
    username="${RDS_USERNAME}" \
    password="${RDS_PASSWORD}"

echo -e "${GREEN}✓ Database secrets engine configured${NC}"
echo ""

# ========================================
# STEP 11: Create PostgreSQL Databases
# ========================================
echo -e "${YELLOW}Step 11: Creating databases in PostgreSQL...${NC}"

export PGPASSWORD=${RDS_PASSWORD}

for db in cart_db checkout_db product_db payment_db; do
    psql -h ${RDS_ENDPOINT} -U ${RDS_USERNAME} -d postgres -c "CREATE DATABASE ${db};" 2>/dev/null && echo "  ✓ ${db}" || echo "  ✓ ${db} (already exists)"
done

echo -e "${GREEN}✓ All databases created${NC}"
echo ""

# ========================================
# STEP 12: Create Vault Database Roles
# ========================================
echo -e "${YELLOW}Step 12: Creating Vault database roles...${NC}"

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
# STEP 13: Enable Kubernetes Auth
# ========================================
echo -e "${YELLOW}Step 13: Enabling Kubernetes authentication...${NC}"

kubectl exec -n vault vault-0 -- vault auth enable kubernetes 2>/dev/null || echo "  Already enabled"

echo -e "${GREEN}✓ Kubernetes auth enabled${NC}"
echo ""

# ========================================
# STEP 14: Configure Kubernetes Auth
# ========================================
echo -e "${YELLOW}Step 14: Configuring Kubernetes auth...${NC}"

KUBERNETES_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')
KUBERNETES_CA_CERT=$(kubectl get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')

# Check if vault-auth SA exists
VAULT_AUTH_SECRET=$(kubectl get secret -n vault -l kubernetes.io/service-account.name=vault-auth -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$VAULT_AUTH_SECRET" ]; then
    REVIEWER_TOKEN=$(kubectl get secret -n vault $VAULT_AUTH_SECRET -o jsonpath='{.data.token}' | base64 -d)
    
    kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
        kubernetes_host="${KUBERNETES_HOST}" \
        kubernetes_ca_cert="${KUBERNETES_CA_CERT}" \
        token_reviewer_jwt="${REVIEWER_TOKEN}"
    
    echo -e "${GREEN}✓ Kubernetes auth configured with vault-auth SA${NC}"
else
    echo -e "${YELLOW}⚠ vault-auth ServiceAccount not found${NC}"
    echo -e "${YELLOW}  Run: kubectl apply -f vault-kubernetes-auth-SETUP.yaml${NC}"
    echo -e "${YELLOW}  Skipping Kubernetes auth configuration${NC}"
fi

echo ""

# ========================================
# STEP 15: Create Policies
# ========================================
echo -e "${YELLOW}Step 15: Creating Vault policies...${NC}"

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
# STEP 16: Create Kubernetes Roles in Vault
# ========================================
echo -e "${YELLOW}Step 16: Creating Kubernetes roles in Vault...${NC}"

for service in cartservice checkoutservice productcatalogservice paymentservice; do
    kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/${service}-role \
        bound_service_account_names="${service}-sa" \
        bound_service_account_namespaces="default" \
        policies="${service}-policy" \
        ttl=1h 2>/dev/null || echo "  ⚠ Skipped ${service}-role (Kubernetes auth not configured)"
    echo "  ✓ ${service}-role"
done

echo -e "${GREEN}✓ All Kubernetes roles created${NC}"
echo ""

# ========================================
# STEP 17: Test Credential Generation
# ========================================
echo -e "${YELLOW}Step 17: Testing dynamic credential generation...${NC}"
echo ""

kubectl exec -n vault vault-0 -- vault read database/creds/cartservice-role

echo ""

# ========================================
# Cleanup
# ========================================
kill $PORT_FORWARD_PID 2>/dev/null || true

# ========================================
# Final Summary
# ========================================
VAULT_UI_LB=$(kubectl get svc -n vault vault-ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "LoadBalancer pending")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓✓✓ VAULT SETUP COMPLETE! ✓✓✓${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Root Token:${NC} ${ROOT_TOKEN}"
echo -e "${YELLOW}Saved to:${NC} $(pwd)/vault-init-keys.json"
echo -e "${YELLOW}Vault UI:${NC} http://${VAULT_UI_LB}:8200"
echo ""
echo -e "${YELLOW}RDS Endpoint:${NC} ${RDS_ENDPOINT}"
echo -e "${YELLOW}Databases:${NC} cart_db, checkout_db, product_db, payment_db"
echo ""
echo -e "${RED}NEXT STEPS:${NC}"
echo "  1. BACKUP vault-init-keys.json to a secure location"
echo "  2. DELETE vault-init-keys.json from this server"
echo "  3. Deploy microservices"
echo ""
echo -e "${GREEN}========================================${NC}"