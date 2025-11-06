#!/bin/bash
# ========================================
# Complete Platform Installation Script
# Combines Vault setup + All components
# Windows Git Bash Compatible
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detect OS
OS=$(uname -s)
if [[ "$OS" == *"MINGW"* ]] || [[ "$OS" == *"MSYS"* ]]; then
    echo -e "${BLUE}Detected: Windows Git Bash${NC}"
    IS_WINDOWS=true
else
    echo -e "${BLUE}Detected: Linux/macOS${NC}"
    IS_WINDOWS=false
fi

echo -e "${BLUE}=========================================="
echo "  MICROSERVICES PLATFORM INSTALLATION"
echo "==========================================${NC}"
echo ""

# ========================================
# HELPER FUNCTIONS
# ========================================

check_resources() {
  echo -e "${YELLOW}Checking cluster resources...${NC}"
  
  # Check if kubectl is working
  if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to cluster${NC}"
    exit 1
  fi
  
  # Get node info
  NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
  echo "Nodes: $NODE_COUNT"
  
  kubectl top nodes 2>/dev/null || echo "Note: Metrics server not available"
  echo ""
}

wait_for_pods() {
  local namespace=$1
  local label=$2
  local timeout=${3:-300}
  
  echo -e "${YELLOW}Waiting for pods in $namespace with label $label...${NC}"
  
  if kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
    echo -e "${GREEN}✅ Pods ready${NC}"
  else
    echo -e "${YELLOW}⚠️  Timeout or no pods found, continuing...${NC}"
  fi
  echo ""
}

verify_webhook() {
  local webhook_name=$1
  
  echo -e "${YELLOW}Verifying webhook: $webhook_name...${NC}"
  
  if kubectl get mutatingwebhookconfigurations "$webhook_name" &>/dev/null; then
    echo -e "${GREEN}✅ Webhook exists${NC}"
    
    # Check endpoints
    local service_ns=$(kubectl get mutatingwebhookconfigurations "$webhook_name" -o jsonpath='{.webhooks[0].clientConfig.service.namespace}' 2>/dev/null)
    local service_name=$(kubectl get mutatingwebhookconfigurations "$webhook_name" -o jsonpath='{.webhooks[0].clientConfig.service.name}' 2>/dev/null)
    
    if [ -n "$service_ns" ] && [ -n "$service_name" ]; then
      local endpoints=$(kubectl get endpoints -n "$service_ns" "$service_name" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
      if [ -n "$endpoints" ]; then
        echo -e "${GREEN}✅ Webhook has endpoints${NC}"
      else
        echo -e "${RED}⚠️  Webhook has no endpoints${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}⚠️  Webhook not found (may not be installed yet)${NC}"
  fi
  echo ""
}

# ========================================
# PHASE 0: PRE-REQUISITES
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 0: Pre-requisites"
echo "==========================================${NC}"

check_resources

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}❌ Helm not found${NC}"
    echo "Install from: https://helm.sh/docs/intro/install/"
    exit 1
fi

echo -e "${GREEN}✅ Helm found: $(helm version --short)${NC}"
echo ""
sleep 2

# ========================================
# PHASE 1: SERVICE ACCOUNTS & RBAC
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 1: Creating Service Accounts"
echo "==========================================${NC}"

# Create vault namespace first
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Check if vault-kubernetes-auth-SETUP.yaml exists
if [ -f "../kubernetes/vault-kubernetes-auth-SETUP.yaml" ]; then
  echo "Applying Vault Kubernetes Auth Setup..."
  kubectl apply -f vault-kubernetes-auth-SETUP.yaml
  echo -e "${GREEN}✅ Service accounts created${NC}"
else
  echo -e "${YELLOW}⚠️  vault-kubernetes-auth-SETUP.yaml not found${NC}"
  echo "Creating service accounts manually..."
  
  
  # Create service accounts for microservices
  for sa in cartservice-sa checkoutservice-sa paymentservice-sa productcatalogservice-sa; do
    kubectl create serviceaccount $sa -n default --dry-run=client -o yaml | kubectl apply -f -
  done
  
  # Create vault service account
  kubectl create serviceaccount vault -n vault --dry-run=client -o yaml | kubectl apply -f -
  
  # Create vault-auth-delegator ClusterRoleBinding
  kubectl create clusterrolebinding vault-auth-delegator \
    --clusterrole=system:auth-delegator \
    --serviceaccount=vault:vault \
    --dry-run=client -o yaml | kubectl apply -f -
  
  echo -e "${GREEN}✅ Service accounts created manually${NC}"
fi

echo ""
sleep 2

# ========================================
# PHASE 2: INSTALL VAULT
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 2: Installing Vault"
echo "==========================================${NC}"

# Add HashiCorp Helm repository
echo "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Check if Vault is already installed
if helm list -n vault | grep -q vault; then
  echo -e "${YELLOW}⚠️  Vault already installed${NC}"
  read -p "Reinstall? [y/N]: " reinstall
  if [[ "$reinstall" =~ ^[Yy]$ ]]; then
    helm uninstall vault -n vault
    kubectl delete namespace vault
    sleep 10
    kubectl create namespace vault
  else
    echo "Skipping Vault installation"
  fi
fi

# Install Vault with HA enabled
echo "Installing Vault with HA configuration..."
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3" \
  --set "server.ha.raft.enabled=true" \
  --set "injector.enabled=true" \
  --set "injector.resources.requests.cpu=100m" \
  --set "injector.resources.requests.memory=128Mi" \
  --set "injector.resources.limits.cpu=250m" \
  --set "injector.resources.limits.memory=256Mi" \
  --wait --timeout=10m

echo "Waiting for Vault pods..."
wait_for_pods "vault" "app.kubernetes.io/name=vault" 300
wait_for_pods "vault" "app.kubernetes.io/name=vault-agent-injector" 300

echo -e "${GREEN}✅ Vault installed${NC}"
echo ""
sleep 3

# ========================================
# PHASE 3: INITIALIZE & CONFIGURE VAULT
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 3: Initializing & Configuring Vault"
echo "==========================================${NC}"

# Check if vault-setup-eks-final.sh exists
if [ -f "./vault-setup-eks-final.sh" ]; then
  echo "Running vault-setup-eks-final.sh..."
  chmod +x vault-setup-eks-final.sh
  
  # Run the existing setup script
  ./vault-setup-eks-final.sh
  
  echo -e "${GREEN}✅ Vault configured${NC}"
else
  echo -e "${YELLOW}⚠️  vault-setup-eks-final.sh not found${NC}"
  echo "You'll need to manually initialize and configure Vault"
  echo ""
  echo "Steps:"
  echo "1. Initialize: kubectl exec -n vault vault-0 -- vault operator init"
  echo "2. Unseal all pods"
  echo "3. Configure database secrets engine"
  echo "4. Configure Kubernetes auth"
fi

verify_webhook "vault-agent-injector-cfg"

check_resources
echo ""
sleep 3

# ========================================
# PHASE 4: INSTALL ISTIO
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 4: Installing Istio"
echo "==========================================${NC}"

ISTIO_VERSION="1.20.3"

# Check if istioctl exists
if ! command -v istioctl &> /dev/null; then
  echo "Downloading Istio..."
  
  if [ "$IS_WINDOWS" = true ]; then
    if [ ! -d "istio-${ISTIO_VERSION}" ]; then
      curl -L -o istio.zip "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-win.zip"
      unzip -q istio.zip
      rm istio.zip
    fi
    export PATH=$PATH:$(pwd)/istio-${ISTIO_VERSION}/bin
  else
    if [ ! -d "istio-${ISTIO_VERSION}" ]; then
      curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
    fi
    export PATH=$PATH:$(pwd)/istio-${ISTIO_VERSION}/bin
  fi
else
  echo -e "${GREEN}✅ istioctl found${NC}"
fi

# Install Istio with resource limits
echo "Installing Istio with demo profile..."
istioctl install --set profile=demo \
  --set values.pilot.resources.requests.cpu=100m \
  --set values.pilot.resources.requests.memory=128Mi \
  --set values.pilot.resources.limits.cpu=500m \
  --set values.pilot.resources.limits.memory=512Mi \
  --set values.global.proxy.resources.requests.cpu=50m \
  --set values.global.proxy.resources.requests.memory=64Mi \
  --set values.global.proxy.resources.limits.cpu=100m \
  --set values.global.proxy.resources.limits.memory=128Mi -y

# Enable sidecar injection for default namespace
kubectl label namespace default istio-injection=enabled --overwrite

echo "Installing Istio observability addons..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/prometheus.yaml || true
kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/grafana.yaml || true
kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/kiali.yaml || true
kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/jaeger.yaml || true

wait_for_pods "istio-system" "app=istiod" 300

echo -e "${GREEN}✅ Istio installed${NC}"

# CRITICAL: Verify Vault webhook still healthy after Istio
echo -e "${YELLOW}Verifying Vault webhook after Istio installation...${NC}"
sleep 5
verify_webhook "vault-agent-injector-cfg"

# Check if vault-agent-injector is still running
if ! kubectl get pods -n vault -l app.kubernetes.io/name=vault-agent-injector | grep -q "Running"; then
  echo -e "${RED}⚠️  Vault Agent Injector not running after Istio install!${NC}"
  echo "Restarting..."
  kubectl rollout restart deployment vault-agent-injector -n vault
  wait_for_pods "vault" "app.kubernetes.io/name=vault-agent-injector" 300
fi

verify_webhook "istio-sidecar-injector"

check_resources
echo ""
sleep 3

# ========================================
# PHASE 5: INSTALL ARGOCD
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 5: Installing ArgoCD"
echo "==========================================${NC}"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

wait_for_pods "argocd" "app.kubernetes.io/name=argocd-server" 300

# Patch service to LoadBalancer
echo "Exposing ArgoCD server..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

echo ""
echo "Getting ArgoCD admin password..."
sleep 10
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "password-not-ready")

echo ""
echo -e "${GREEN}========================================="
echo "ArgoCD Credentials"
echo "=========================================${NC}"
echo "Username: admin"
echo "Password: ${ARGOCD_PASSWORD}"
echo ""
echo "Get LoadBalancer URL:"
echo "kubectl get svc argocd-server -n argocd"
echo -e "${GREEN}=========================================${NC}"
echo ""

echo -e "${GREEN}✅ ArgoCD installed${NC}"

# Verify webhooks still healthy
verify_webhook "vault-agent-injector-cfg"
verify_webhook "istio-sidecar-injector"

check_resources
echo ""
sleep 3

# ========================================
# PHASE 6: INSTALL ARGO ROLLOUTS
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 6: Installing Argo Rollouts"
echo "==========================================${NC}"

kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

wait_for_pods "argo-rollouts" "app.kubernetes.io/name=argo-rollouts" 300

echo -e "${GREEN}✅ Argo Rollouts installed${NC}"

check_resources
echo ""
sleep 3

# ========================================
# PHASE 7: INSTALL DATADOG (OPTIONAL)
# ========================================

echo -e "${BLUE}=========================================="
echo "  PHASE 7: Installing Datadog (Optional)"
echo "==========================================${NC}"

read -p "Install Datadog monitoring? [y/N]: " install_dd

if [[ "$install_dd" =~ ^[Yy]$ ]]; then
  
  # Check for API key
  if [ -z "$DD_API_KEY" ]; then
    echo -e "${YELLOW}Datadog API Key not set${NC}"
    read -p "Enter Datadog API Key: " DD_API_KEY
    export DD_API_KEY
  fi
  
  if [ -z "$DD_APP_KEY" ]; then
    echo -e "${YELLOW}Datadog APP Key not set${NC}"
    read -p "Enter Datadog APP Key: " DD_APP_KEY
    export DD_APP_KEY
  fi
  
  echo "Using Datadog API Key: ${DD_API_KEY:0:10}..."
  
  # Add Helm repo
  helm repo add datadog https://helm.datadoghq.com
  helm repo update
  
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
  
  # Install Datadog with resource limits
  helm upgrade --install datadog datadog/datadog \
    --namespace datadog \
    --set datadog.apiKey="${DD_API_KEY}" \
    --set datadog.appKey="${DD_APP_KEY}" \
    --set datadog.site="datadoghq.com" \
    --set datadog.logs.enabled=true \
    --set datadog.logs.containerCollectAll=true \
    --set datadog.apm.portEnabled=true \
    --set datadog.processAgent.enabled=true \
    --set datadog.resources.requests.cpu=100m \
    --set datadog.resources.requests.memory=256Mi \
    --set datadog.resources.limits.cpu=200m \
    --set datadog.resources.limits.memory=512Mi \
    --set clusterAgent.enabled=true \
    --set clusterAgent.replicas=2
  
  echo "Waiting for Datadog agents..."
  sleep 30
  kubectl get pods -n datadog
  
  echo -e "${GREEN}✅ Datadog installed${NC}"
else
  echo "Skipping Datadog installation"
fi

echo ""
sleep 2

# ========================================
# FINAL VERIFICATION
# ========================================

echo -e "${BLUE}=========================================="
echo "  FINAL VERIFICATION"
echo "==========================================${NC}"

echo ""
echo "Checking all webhooks..."
verify_webhook "vault-agent-injector-cfg"
verify_webhook "istio-sidecar-injector"

echo ""
echo "Checking all pods..."
echo ""
echo "Vault:"
kubectl get pods -n vault
echo ""
echo "Istio:"
kubectl get pods -n istio-system
echo ""
echo "ArgoCD:"
kubectl get pods -n argocd
echo ""
echo "Argo Rollouts:"
kubectl get pods -n argo-rollouts
echo ""

if [[ "$install_dd" =~ ^[Yy]$ ]]; then
  echo "Datadog:"
  kubectl get pods -n datadog
  echo ""
fi

check_resources

echo ""
echo -e "${BLUE}=========================================="
echo "  INSTALLATION SUMMARY"
echo "==========================================${NC}"
echo ""
echo -e "${GREEN}✅ Vault: Installed and configured${NC}"
echo -e "${GREEN}✅ Vault Agent Injector: $(kubectl get pods -n vault -l app.kubernetes.io/name=vault-agent-injector -o jsonpath='{.items[0].status.phase}')${NC}"
echo -e "${GREEN}✅ Istio: Installed with demo profile${NC}"
echo -e "${GREEN}✅ ArgoCD: Installed (LoadBalancer pending)${NC}"
echo -e "${GREEN}✅ Argo Rollouts: Installed${NC}"

if [[ "$install_dd" =~ ^[Yy]$ ]]; then
  echo -e "${GREEN}✅ Datadog: Installed${NC}"
fi

echo ""
echo -e "${YELLOW}========================================="
echo "  NEXT STEPS"
echo "=========================================${NC}"
echo ""
echo "1. Get ArgoCD URL:"
echo "   kubectl get svc argocd-server -n argocd"
echo ""
echo "2. Login to ArgoCD:"
echo "   Username: admin"
echo "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo "3. Run pre-flight checks before deploying apps:"
echo "   ./pre-flight-check.sh"
echo ""
echo "4. Deploy your microservices:"
echo "   kubectl apply -f k8s/"
echo "   OR use ArgoCD to sync"
echo ""
echo "5. Monitor deployment:"
echo "   kubectl get pods -n default -w"
echo ""
echo -e "${GREEN}========================================="
echo "  ✅ PLATFORM READY!"
echo "=========================================${NC}"
echo ""
