#!/bin/bash
# ========================================
# FILE: scripts/install-istio.sh
# Install Istio Service Mesh
# ========================================

set -e

echo "========================================="
echo "Installing Istio Service Mesh"
echo "========================================="

# Check if istioctl already exists
if command -v istioctl &> /dev/null; then
    echo "✓ istioctl already installed"
    istioctl version --remote=false
else
    echo "Downloading Istio..."
    cd ~
    curl -L https://istio.io/downloadIstio | sh -
    
    # Move to /usr/local/bin
    ISTIO_DIR=$(ls -d istio-* | head -1)
    cd $ISTIO_DIR
    sudo cp bin/istioctl /usr/local/bin/
    cd ..
    
    echo "✓ Istio downloaded and installed"
fi

# Install Istio on the cluster
echo "Installing Istio on EKS cluster..."
istioctl install --set profile=demo -y

# Enable sidecar injection for default namespace
echo "Enabling sidecar injection for default namespace..."
kubectl label namespace default istio-injection=enabled --overwrite

# Install Istio addons (Kiali, Prometheus, Grafana, Jaeger)
echo "Installing Istio addons..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/jaeger.yaml

# Wait for addons to be ready
echo "Waiting for Kiali to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/kiali -n istio-system

echo "========================================="
echo "✓ Istio Installation Complete!"
echo "========================================="
echo ""
echo "Access Dashboards:"
echo "1. Kiali (Service Mesh Dashboard):"
echo "   kubectl port-forward svc/kiali -n istio-system 20001:20001"
echo "   http://localhost:20001"
echo ""
echo "2. Grafana (Metrics):"
echo "   kubectl port-forward svc/grafana -n istio-system 3000:3000"
echo "   http://localhost:3000"
echo ""
echo "3. Jaeger (Distributed Tracing):"
echo "   kubectl port-forward svc/tracing -n istio-system 16686:16686"
echo "   http://localhost:16686"
echo ""
echo "Verify installation:"
echo "   kubectl get pods -n istio-system"
echo "   kubectl get ns default --show-labels"
echo "========================================="
