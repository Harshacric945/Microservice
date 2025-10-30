# Complete Post-Installation Workflow

After Vault, ArgoCD, Istio, and Datadog are installed, follow these steps.

---

## **Step 1: Access All Dashboards**

### 1.1 Vault UI
```bash
# Get Vault URL
kubectl get svc vault-ui -n vault

# Access: http://<EXTERNAL-IP>:8200
# Login with root token from vault-keys.json
```

### 1.2 ArgoCD UI
```bash
# Get ArgoCD URL
kubectl get svc argocd-server -n argocd

# Get password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access: http://<EXTERNAL-IP>
# Username: admin
# Password: <from above>
```

### 1.3 Kiali (Istio Dashboard)
```bash
# Port forward Kiali
kubectl port-forward -n istio-system svc/kiali 20001:20001

# Access: http://localhost:20001
# No login needed
```

### 1.4 Grafana (Istio Metrics)
```bash
# Port forward Grafana
kubectl port-forward -n istio-system svc/grafana 3000:3000

# Access: http://localhost:3000
# No login needed
```

### 1.5 Jaeger (Distributed Tracing)
```bash
# Port forward Jaeger
kubectl port-forward -n istio-system svc/tracing 16686:80

# Access: http://localhost:16686
```

### 1.6 Argo Rollouts Dashboard
```bash
# Method 1: Plugin
kubectl argo rollouts dashboard

# Method 2: Port forward
kubectl port-forward -n argo-rollouts svc/argo-rollouts-dashboard 3100:3100

# Access: http://localhost:3100
```

### 1.7 Datadog UI
```bash
# Access: https://app.datadoghq.com
# Login with your Datadog credentials
# Go to: Infrastructure → Kubernetes
```

---

## **Step 2: Deploy Your Microservices**

### 2.1 Create ArgoCD Application

```bash
# Create ArgoCD app pointing to your Git repo
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: microservices
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-repo/microservices
    targetRevision: main
    path: K8S-manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
```

### 2.2 Verify Sync

```bash
# Check ArgoCD sync status
kubectl get applications -n argocd

# View in UI: http://<argocd-url>
```

---

## **Step 3: Verify Istio Sidecar Injection**

### 3.1 Check Namespace Label

```bash
# Verify default namespace has Istio injection enabled
kubectl get namespace default --show-labels

# Should show: istio-injection=enabled

# If not:
kubectl label namespace default istio-injection=enabled --overwrite
```

### 3.2 Check Pods Have Sidecars

```bash
# List pods with container count
kubectl get pods -o wide

# Each pod should show 2/2 (app + istio-proxy)
# Example:
# NAME              READY   STATUS
# frontend-xxx      2/2     Running
# cartservice-xxx   2/2     Running
```

### 3.3 If Sidecars Not Injected

```bash
# Restart pods to trigger injection
kubectl rollout restart deployment/frontend
kubectl rollout restart deployment/cartservice
# ... repeat for all deployments
```

---

## **Step 4: View in Kiali**

Now Kiali should show your services!

```bash
# Open Kiali
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Go to: http://localhost:20001

# Click: Graph → Namespace: default
```

**You should see:**
- Service topology (boxes connected by lines)
- Request rates (requests/second on edges)
- Success/error rates (colors: green=good, red=errors)
- Response times

**Generate traffic to see activity:**
```bash
# Get frontend URL
kubectl get svc frontend-external

# Hit it repeatedly
for i in {1..100}; do curl http://<frontend-url>; done
```

---

## **Step 5: View in Grafana**

```bash
# Open Grafana
kubectl port-forward -n istio-system svc/grafana 3000:3000
# Go to: http://localhost:3000

# Click: Dashboards → Istio → Istio Service Dashboard
```

**You'll see:**
- Request volume
- Request duration (p50, p95, p99)
- Success rate
- 4xx/5xx errors

---

## **Step 6: View in Jaeger (Tracing)**

```bash
# Open Jaeger
kubectl port-forward -n istio-system svc/tracing 16686:80
# Go to: http://localhost:16686

# Select service: frontend
# Click: Find Traces
```

**You'll see:**
- End-to-end traces (frontend → cart → product → payment)
- Latency breakdown per service
- Error traces highlighted in red

---

## **Step 7: Verify Datadog Integration**

### 7.1 Check Datadog Agents

```bash
kubectl get pods -n datadog

# Should show:
# datadog-xxxxx        4/4   Running  (one per node)
# datadog-cluster-agent-xxx   1/1   Running
```

### 7.2 View in Datadog UI

Go to: https://app.datadoghq.com

**Infrastructure → Kubernetes:**
- See your EKS cluster
- Node count, pod count
- Resource utilization

**APM → Services:**
- Your microservices (if instrumented)
- Request rates, latency, errors

**Logs → Search:**
- Filter by namespace: `kube_namespace:default`
- See logs from all pods

---

## **Step 8: Test Argo Rollouts (Canary Deployment)**

### 8.1 Create a Rollout

```bash
# Convert a Deployment to Rollout
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: frontend-rollout
  namespace: default
spec:
  replicas: 3
  strategy:
    canary:
      steps:
      - setWeight: 20
      - pause: {duration: 1m}
      - setWeight: 50
      - pause: {duration: 1m}
      - setWeight: 80
      - pause: {duration: 30s}
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: frontend
        image: your-frontend-image:v1
        ports:
        - containerPort: 8080
EOF
```

### 8.2 Trigger Canary Update

```bash
# Update to new version
kubectl argo rollouts set image frontend-rollout frontend=your-frontend-image:v2

# Watch progress
kubectl argo rollouts get rollout frontend-rollout --watch
```

### 8.3 View in Dashboard

```bash
# Open Rollouts dashboard
kubectl argo rollouts dashboard
# Go to: http://localhost:3100

# Click on: frontend-rollout
```

**You'll see:**
- Canary progress bar (20% → 50% → 80% → 100%)
- Old vs new replica counts
- Pause/Abort buttons

---

## **Step 9: Test Vault Dynamic Secrets**

### 9.1 Get DB Credentials from Vault

```bash
export VAULT_ADDR="http://$(kubectl get svc vault-ui -n vault -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8200"
export VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')

# Generate credentials for cart service
vault read database/creds/cartservice-role
```

**Output:**
```
Key                Value
---                -----
lease_id           database/creds/cartservice-role/abc123
lease_duration     1h
username           v-root-cartservi-xyz
password           A1b2C3d4E5f6
```

### 9.2 Verify in PostgreSQL

```bash
# Get RDS endpoint
terraform output rds_endpoint

# Connect to RDS
PGPASSWORD=$(terraform output -raw rds_password) psql -h <rds-endpoint> -U vaultadmin -d postgres

# List users
\du

# You should see the dynamic user: v-root-cartservi-xyz
```