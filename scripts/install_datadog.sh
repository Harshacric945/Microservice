# ========================================
# FILE: scripts/install-datadog.sh
# Install Datadog Monitoring
# ========================================

#!/bin/bash
set -e

echo "========================================="
echo "Installing Datadog Monitoring"
echo "========================================="

# Check if DD_API_KEY is set
if [ -z "$DD_API_KEY" ]; then
    echo "ERROR: DD_API_KEY environment variable not set"
    echo "Please set it first:"
    echo "  export DD_API_KEY='your-datadog-api-key'"
    echo ""
    echo "Get your API key from:"
    echo "  https://app.datadoghq.com/organization-settings/api-keys"
    exit 1
fi

echo "Using Datadog API Key: ${DD_API_KEY:0:8}..." # Show first 8 chars only

# Add Datadog Helm repository
echo "Adding Datadog Helm repository..."
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Create datadog namespace
kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -

# Create values file
echo "Creating Datadog values file..."
cat > /tmp/datadog-values.yaml <<EOF
datadog:
  apiKey: "${DD_API_KEY}"
  site: "datadoghq.com"  # Change to datadoghq.eu for EU
  
  # Enable log collection
  logs:
    enabled: true
    containerCollectAll: true
  
  # Enable APM (Application Performance Monitoring)
  apm:
    portEnabled: true
    enabled: true
  
  # Enable process monitoring
  processAgent:
    enabled: true
    processCollection: true
  
  # Enable network monitoring
  networkMonitoring:
    enabled: true

  # Tag everything
  tags:
    - "env:production"
    - "project:microservices-ecommerce"
    - "cluster:micro-eks"

# Cluster Agent (aggregates data)
clusterAgent:
  enabled: true
  replicas: 2
  
  metricsProvider:
    enabled: true  # For HPA with custom metrics
  
  admissionController:
    enabled: true  # For APM auto-instrumentation

# Node Agent (DaemonSet)
agents:
  image:
    tag: "7"  # Latest Datadog Agent 7
  
  # Resource limits
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 400m
      memory: 512Mi
  
  # Tolerations for all nodes
  tolerations:
    - operator: Exists

EOF

# Install Datadog
echo "Installing Datadog agent..."
helm install datadog datadog/datadog \
  -f /tmp/datadog-values.yaml \
  --namespace datadog

# Wait for agents to be ready
echo "Waiting for Datadog agents to be ready..."
kubectl wait --for=condition=ready pod -l app=datadog-agent -n datadog --timeout=300s

# Clean up temp file
rm /tmp/datadog-values.yaml

echo "========================================="
echo "✓ Datadog Installation Complete!"
echo "========================================="
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n datadog"
echo "  kubectl get daemonset -n datadog"
echo ""
echo "Check agent status:"
echo "  kubectl exec -n datadog -it \$(kubectl get pod -n datadog -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}') -- agent status"
echo ""
echo "Access Datadog Dashboard:"
echo "  https://app.datadoghq.com"
echo ""
echo "To configure Slack alerts:"
echo "  1. Go to Datadog → Integrations → Slack"
echo "  2. Connect your Slack workspace"
echo "  3. Create monitors and set notification channel to @slack"
echo "========================================="
