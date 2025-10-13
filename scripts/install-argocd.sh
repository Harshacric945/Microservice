# ========================================
# FILE: scripts/install-argocd.sh
# Install ArgoCD (GitOps)
# ========================================

#!/bin/bash
set -e

echo "========================================="
echo "Installing ArgoCD"
echo "========================================="

# Create namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
echo "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Expose ArgoCD server
echo "Exposing ArgoCD server as LoadBalancer..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Get initial admin password
echo ""
echo "========================================="
echo "✓ ArgoCD Installation Complete!"
echo "========================================="
echo ""
echo "ArgoCD Server URL:"
ARGOCD_LB=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [ -z "$ARGOCD_LB" ]; then
    echo "  LoadBalancer provisioning... Check with:"
    echo "  kubectl get svc argocd-server -n argocd"
else
    echo "  http://${ARGOCD_LB}"
fi
echo ""
echo "Initial Admin Credentials:"
echo "  Username: admin"
echo "  Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
echo ""
echo "IMPORTANT: Change the password after first login!"
echo ""
echo "Port-forward for local access:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080"
echo ""
echo "Install ArgoCD CLI (optional):"
echo "  curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
echo "  sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd"
echo "========================================="

