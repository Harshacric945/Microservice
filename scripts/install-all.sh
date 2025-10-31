#!/bin/bash
# ========================================
# FILE: install-all.sh
# Master installation script for all components
# Windows Git Bash Compatible
# ========================================

set -e

echo "========================================="
echo "MICROSERVICES PLATFORM INSTALLATION"
echo "========================================="
echo ""

# Detect OS
OS=$(uname -s)
if [[ "$OS" == *"MINGW"* ]] || [[ "$OS" == *"MSYS"* ]]; then
    echo "✓ Detected: Windows Git Bash"
    IS_WINDOWS=true
else
    echo "✓ Detected: Linux/macOS"
    IS_WINDOWS=false
fi

echo ""

# ========================================
# 1. ARGO ROLLOUTS
# ========================================
install_argo_rollouts() {
    echo "========================================="
    echo "Installing Argo Rollouts"
    echo "========================================="
    
    kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
    
    echo "Waiting for Argo Rollouts controller..."
    kubectl wait --for=condition=available --timeout=300s deployment/argo-rollouts -n argo-rollouts || {
        echo "WARNING: Timeout waiting for Argo Rollouts"
    }
    
    echo "✓ Argo Rollouts installed"
    echo ""
}

# ========================================
# 2. ARGOCD
# ========================================
install_argocd() {
    echo "========================================="
    echo "Installing ArgoCD"
    echo "========================================="
    
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    echo "Waiting for ArgoCD server..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || {
        echo "WARNING: Timeout waiting for ArgoCD"
    }
    
    # Patch service to LoadBalancer
    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
    
    echo ""
    echo "Getting ArgoCD admin password..."
    sleep 10
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    echo ""
    echo "========================================="
    echo "ArgoCD Credentials"
    echo "========================================="
    echo "Username: admin"
    echo "Password: ${ARGOCD_PASSWORD}"
    echo ""
    echo "Get LoadBalancer URL:"
    echo "kubectl get svc argocd-server -n argocd"
    echo "========================================="
    echo ""
}

# ========================================
# 3. ISTIO
# ========================================
install_istio() {
    echo "========================================="
    echo "Installing Istio Service Mesh"
    echo "========================================="
    
    ISTIO_VERSION="1.20.3"
    
    if [ "$IS_WINDOWS" = true ]; then
        echo "Downloading Istio for Windows..."
        
        if [ ! -d "istio-${ISTIO_VERSION}" ]; then
            curl -L -o istio.zip "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-win.zip"
            unzip -q istio.zip
            rm istio.zip
        fi
        
        export PATH=$PATH:$(pwd)/istio-${ISTIO_VERSION}/bin
        
    else
        echo "Downloading Istio for Linux/macOS..."
        
        if [ ! -d "istio-${ISTIO_VERSION}" ]; then
            curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
        fi
        
        export PATH=$PATH:$(pwd)/istio-${ISTIO_VERSION}/bin
    fi
    
    echo "Installing Istio on cluster..."
    istioctl install --set profile=demo -y
    
    # Enable injection
    kubectl label namespace default istio-injection=enabled --overwrite
    
    echo "Installing Istio addons..."
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/prometheus.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/grafana.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/kiali.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/jaeger.yaml
    
    echo "Waiting for Kiali..."
    kubectl wait --for=condition=available --timeout=300s deployment/kiali -n istio-system || {
        echo "WARNING: Timeout waiting for Kiali"
    }
    
    echo "✓ Istio installed"
    echo ""
}

# ========================================
# 4. DATADOG
# ========================================
install_datadog() {
    echo "========================================="
    echo "Installing Datadog Monitoring"
    echo "========================================="

    # Check for API key
    if [ -z "$DD_API_KEY" ]; then
        echo "ERROR: DD_API_KEY environment variable not set"
        echo "Please run: export DD_API_KEY='your-datadog-api-key'"
        return 1
    fi

    # Check for APP key
   if [ -z "$DD_APP_KEY" ]; then
       echo "ERROR: DD_APP_KEY not set"
       echo "Get it from: https://app.datadoghq.com/organization-settings/application-keys"
       echo ""
       echo "Run: export DD_APP_KEY='your-app-key'"
       return 1
   fi

    echo "Using Datadog API Key: ${DD_API_KEY:0:10}..."
    echo "Using Datadog APP Key: ${DD_APP_KEY:0:10}..."
    
    # Add Helm repo
    helm repo add datadog https://helm.datadoghq.com
    helm repo update
    
    kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
    
    # Create values file
    cat > /tmp/datadog-values.yaml <<EOF
datadog:
  apiKey: ${DD_API_KEY}
  site: datadoghq.com
  logs:
    enabled: true
    containerCollectAll: true
  apm:
    portEnabled: true
  processAgent:
    enabled: true
  systemProbe:
    enabled: true

clusterAgent:
  enabled: true
  replicas: 2
  createPodDisruptionBudget: true
EOF
    
    # Install Datadog
    helm upgrade --install datadog datadog/datadog \
        -f /tmp/datadog-values.yaml \
        -n datadog
    
    echo "Waiting for Datadog agents..."
    sleep 30
    kubectl get pods -n datadog
    
    echo "✓ Datadog installed"
    echo ""
}

# ========================================
# MAIN EXECUTION
# ========================================

echo "Select components to install:"
echo "1) All components"
echo "2) Argo Rollouts only"
echo "3) ArgoCD only"
echo "4) Istio only"
echo "5) Datadog only"
echo "6) Custom selection"
echo ""
read -p "Enter choice [1-6]: " choice

case $choice in
    1)
        install_argo_rollouts
        install_argocd
        install_istio
        install_datadog
        ;;
    2)
        install_argo_rollouts
        ;;
    3)
        install_argocd
        ;;
    4)
        install_istio
        ;;
    5)
        install_datadog
        ;;
    6)
        read -p "Install Argo Rollouts? [y/n]: " ans
        [ "$ans" = "y" ] && install_argo_rollouts
        
        read -p "Install ArgoCD? [y/n]: " ans
        [ "$ans" = "y" ] && install_argocd
        
        read -p "Install Istio? [y/n]: " ans
        [ "$ans" = "y" ] && install_istio
        
        read -p "Install Datadog? [y/n]: " ans
        [ "$ans" = "y" ] && install_datadog
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "========================================="
echo "✓ INSTALLATION COMPLETE"
echo "========================================="
echo ""
echo "Summary:"
kubectl get pods --all-namespaces | grep -E 'argo-rollouts|argocd|istio-system|datadog'
echo ""
