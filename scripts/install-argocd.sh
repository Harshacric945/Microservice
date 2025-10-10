// ========================================
// Install ArgoCD Script
// Save as: scripts/install-argocd.sh
// ========================================

#!/bin/bash
set -e

echo "Installing ArgoCD..."

# Create namespace
kubectl create namespace argocd || true

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Expose ArgoCD server
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Get initial admin password
echo ""
echo "=========================================="
echo "ArgoCD Installation Complete!"
echo "=========================================="
echo ""
echo "ArgoCD Server:"
kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo ""
echo ""
echo "Initial Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "Login:"
echo "  Username: admin"
echo "  Password: (above)"
echo ""
echo "Change password after first login!"
echo "=========================================="
