# ========================================
# FILE: scripts/install-argo-rollouts.sh
# Install Argo Rollouts (Progressive Delivery)
# ========================================

#!/bin/bash
set -e

echo "========================================="
echo "Installing Argo Rollouts"
echo "========================================="

# Create namespace
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

# Install Argo Rollouts
echo "Installing Argo Rollouts controller..."
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Wait for controller to be ready
echo "Waiting for Argo Rollouts controller..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argo-rollouts -n argo-rollouts --timeout=300s

echo ""
echo "========================================="
echo "✓ Argo Rollouts Installation Complete!"
echo "========================================="
echo ""
echo "Install kubectl plugin:"
echo "  curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64"
echo "  chmod +x kubectl-argo-rollouts-linux-amd64"
echo "  sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts"
echo ""
echo "Verify plugin:"
echo "  kubectl argo rollouts version"
echo ""
echo "Access Argo Rollouts Dashboard:"
echo "  kubectl argo rollouts dashboard"
echo "  http://localhost:3100"
echo ""
echo "========================================="
