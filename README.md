Complete EKS Deployment Checklist or guide
Prerequisites (One-Time Setup) 
Install Tools on Windows Laptop

# Run PowerShell as Administrator

# Install Chocolatey (if not already installed)
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Install required tools
```
choco install awscli -y
choco install kubectl -y
choco install terraform -y
choco install kubernetes-helm -y
choco install jq -y
choco install git -y
```

# Optional but recommended
```
choco install postgresql -y  # For DB creation
```

# Verify installations
```
aws --version
kubectl version --client
terraform --version
helm version
jq --version
git --version
```

Configure AWS Credentials
```# Open Git Bash
aws configure

# Enter:
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: ap-south-1
# Default output format: json
```
Phase 1: Infrastructure Setup (30 minutes)
# Clone YOUR fork
git clone https://github.com/YOUR_USERNAME/Microservice.git
cd Microservice

Step 2: Deploy Infrastructure
```
# Initialize Terraform
terraform init

# Review plan
terraform plan

# Deploy (takes 15-20 minutes)
terraform apply

# Save outputs
terraform output > terraform-outputs.txt
```
What gets created:

✅ VPC with public/private/database subnets
✅ EKS cluster (control plane)
✅ 3 EC2 worker nodes (t3.xlarge)
✅ RDS PostgreSQL (db.t3.medium)
✅ Security groups, IAM roles
✅ EBS CSI driver addon

Step 3: Update Kubeconfig
```
aws eks update-kubeconfig --region ap-south-1 --name micro-eks

# Verify
kubectl get nodes
# Should show 3 nodes in Ready state
```
Phase 2: Vault Setup (15 minutes)
```
cd /Microservice/kubernetes

kubectl apply -f vault-kubernetes-auth-SETUP.yaml

# Verify
kubectl get sa -n vault
kubectl get sa -n default | grep -E 'cart|checkout|product|payment'
```
Step 2: Install Vault with Helm
```
cd /Microservice

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

kubectl create namespace vault

helm install vault hashicorp/vault \
  -f vault-manual-values.yaml \
  -n vault

#Run the helm install cmd where the vault-manaul-values.yaml file is present 

# Wait for pods (they'll be 0/1 - this is normal)
kubectl get pods -n vault -w
```
Step 3: Initialize and Configure Vault
```
cd /Microservice/scripts

chmod +x vault-setup-eks-final.sh
./vault-setup-eks-final.sh

# This will:
# ✅ Initialize Vault (5 keys + root token)
# ✅ Unseal all 3 pods
# ✅ Configure database secrets engine
# ✅ Create databases in RDS
# ✅ Configure Kubernetes auth
# ✅ Create policies and roles
# ✅ Enable KV secrets engine
```
Step 4: Backup Keys!
```
# Copy vault-init-keys.json to safe location
cp vault-init-keys.json ~/vault-backup/
# Or upload to password manager

# Get Vault UI URL
kubectl get svc vault-ui -n vault

# Access: http://<EXTERNAL-IP>:8200
# Login with root token from vault-init-keys.json

```
Phase 3: Install Supporting Tools (20 minutes)
Option A: Install All at Once
```
cd /Microservice/scripts

# Set Datadog keys 
export DD_API_KEY="your-api-key"
export DD_APP_KEY="your-app-key"

chmod +x install-all.sh
./install-all.sh

# Select: 1 (All components)

```
Option B: Install One by One
```
# Argo Rollouts
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Get ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Istio
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.20.3 sh -
cd istio-1.20.3
export PATH=$PWD/bin:$PATH
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled --overwrite

# Istio addons
kubectl apply -f https://raw.githubusercontent.com/istio/istio/1.20.3/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/1.20.3/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/1.20.3/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/1.20.3/samples/addons/jaeger.yaml

# Datadog (optional)
helm repo add datadog https://helm.datadoghq.com
helm repo update
kubectl create namespace datadog

cat > datadog-values.yaml <<EOF
datadog:
  apiKey: ${DD_API_KEY}
  appKey: ${DD_APP_KEY}
  site: datadoghq.com
  logs:
    enabled: true
  apm:
    portEnabled: true
clusterAgent:
  enabled: true
  replicas: 2
EOF

helm install datadog datadog/datadog -f datadog-values.yaml -n datadog
```
Phase 4: Deploy Applications (10 minutes)
Step 1: Update Deployment Files
cd /Microservice/K8S-manifests
```
# Edit cartservicedep.yml
# Find: REPLACE_WITH_YOUR_RDS_ENDPOINT
# Replace with: micro-eks-postgresql.cjewwg2cazii.ap-south-1.rds.amazonaws.com

# Get RDS endpoint:
terraform -chdir=../terraform output rds_endpoint
```
Similarly do for the other 3 yaml files checkoutservice.yaml
productcatalogservice.yaml
paymentservice.yaml
Commit Changes
```
cd ..
git add k8s-manifests/
git commit -m "Add Vault-integrated deployment manifests"
git push origin main
```
Step 2: Deploy via kubectl (Quick Test)
```
kubectl apply -f cartservicedep.yml

# Check if Vault injection worked
kubectl get pods -l app=cartservice
# Should show: cartservice-xxx   2/2   Running
#              ^ app + vault-agent

# Check logs
kubectl logs -l app=cartservice -c server
# Should show DB credentials loaded from Vault
```
Step 3: Deploy via ArgoCD (Production Way)
```
# Get ArgoCD URL
kubectl get svc argocd-server -n argocd

# Login to ArgoCD UI
# Username: admin
# Password: <from earlier step>
      OR
cd Microservice/argocd
kubectl apply -f application.yaml
# Watch deployment
argocd app get microservices-ecommerce
argocd app sync microservices-ecommerce
Verify Deployments
Check all pods
kubectl get pods
# Should see:
# - cartservice (with vault sidecar)
# - checkoutservice (with vault sidecar)
# - productcatalogservice (with vault sidecar)
# - paymentservice (with vault sidecar)
# - emailservice
# - currencyservice
# - shippingservice
# - recommendationservice
# - adservice
# - frontend
# - loadgenerator
# Check vault injection
kubectl logs cartservice-xxx -c vault-agent
```
Phase 5: Verify Everything Works (10 minutes)
Check All Dashboards
```
# 1. Vault UI
kubectl get svc vault-ui -n vault
# Access: http://<EXTERNAL-IP>:8200

# 2. ArgoCD UI
kubectl get svc argocd-server -n argocd
# Access: http://<EXTERNAL-IP>

# 3. Kiali (Istio)
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Access: http://localhost:20001

# 4. Grafana
kubectl port-forward -n istio-system svc/grafana 3000:3000
# Access: http://localhost:3000

# 5. Jaeger
kubectl port-forward -n istio-system svc/tracing 16686:80
# Access: http://localhost:16686

# 6. Argo Rollouts
kubectl port-forward -n argo-rollouts svc/argo-rollouts-dashboard 3100:3100
# Access: http://localhost:3100

# 7. Datadog
# Access: https://app.datadoghq.com
```
Verify in UI
1. Wait 2-3 minutes for data to flow
2. Go to Datadog UI → Infrastructure → Kubernetes
3. You should see your cluster!
4. Go to Infrastructure → Host Map
5. You'll see all nodes with metrics
For more information and  detailed setup of dashbaords , monitoring tools access cd scripts/complete_workflow.md

[Open complete_workflow.md](scripts/complete_workflow.md)


Test Vault Integration
```
export VAULT_TOKEN=$(cat vault-init-keys.json | jq -r '.root_token')
export VAULT_ADDR="http://$(kubectl get svc vault-ui -n vault -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8200"

# Generate DB credentials
vault read database/creds/cartservice-role

# Should return:
# username: v-root-cartservi-xxx
# password: random-generated-password
```
Phase 6: Cleanup (When Done)
```
# Delete Helm releases
helm uninstall vault -n vault
helm uninstall datadog -n datadog

# Delete ArgoCD
kubectl delete namespace argocd
kubectl delete namespace argo-rollouts

# Delete Istio
istioctl uninstall --purge -y
kubectl delete namespace istio-system

# Destroy infrastructure (SAVES MONEY!)
cd terraform
terraform destroy

# Confirm: yes
```
Troubleshooting
Vault pods stuck at 0/1
```
# This is NORMAL for sealed Vault
# Check if Running (not Ready):
kubectl get pods -n vault

# If Running 0/1 → Run unseal script
# If Pending → Check node capacity
# If CrashLoopBackOff → Check logs
kubectl logs vault-0 -n vault
```
ArgoCD password not working
```
# Regenerate password
kubectl -n argocd delete secret argocd-initial-admin-secret
kubectl -n argocd rollout restart deployment argocd-server

# Wait 2 minutes, then get new password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
Istio sidecars not injecting
```
# Check namespace label
kubectl get namespace default --show-labels

# Should show: istio-injection=enabled

# If not:
kubectl label namespace default istio-injection=enabled --overwrite

# Restart pods
kubectl rollout restart deployment/cartservice
```
RDS connection fails
```
# Check security group
# RDS SG must allow inbound from EKS worker nodes

# Get worker node security group
terraform output worker_security_group_id

# Add rule in AWS Console:
# Type: PostgreSQL
# Port: 5432
# Source: <worker-sg-id>
```
Configure Slack Integration
1. Go to Datadog UI → Integrations
2. Search "Slack" → Configure
3. Authorize Slack workspace
4. Select channel: #devops-alerts

Create Monitors

CPU Monitor:
Monitors → New Monitor → Metric
Metric: kubernetes.cpu.usage
by: pod_name, kube_namespace
Alert: avg(last_5m) > 70
Warning: avg(last_5m) > 50
Notify: @slack-devops-alerts
Message:
{{#is_alert}}
🚨 High CPU on {{pod_name.name}}
CPU: {{value}}%
Namespace: {{kube_namespace.name}}
{{/is_alert}}

Memory Monitor:
Metric: kubernetes.memory.rss or kubernetes.memory.usage
Alert: > 80% of limit
Warning: > 60% 

Pod CrashLoopBackOff:
Metric: kubernetes.pods.crashed
Alert: > 0
OR
Metric: kubernetes.pods.state_code
where: state:waiting, reason:CrashLoopBackOf where: state:waiting, reason:CrashLoopBackOfff
Alert: > 0

*** Refer the demo scenarios for actual real time testing of the full microservices application ***

cd scripts/demo_scenarios.md

[Open demo_scenarios.md](scripts/demo_scenarios.md)

For Argo rollouts and canary deployment full guide refer

[Open canarydeploymentargorollouts.md](argorollouts/canarydeploymentargorollouts.md)


Testing & Validation (30 minutes)

Step 1: Access Application
```
 # Get frontend LoadBalancer URL 
kubectl get svc frontend-external

# Open in browser 
# You should see  the e-commerce site!
```
Step 2: Test Database Persistence
```
# Add items to cart 
# Refresh page - items should persist 
# Check database
RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d':' -f1)
RDS_PASSWORD=$(terraform output -raw rds_password)
PGPASSWORD=$RDS_PASSWORD psql -h $RDS_ENDPOINT -U vaultadmin -d cart_db -c "SELECT * FROM
cart_item
```
Step 3: Test Vault Dynamic Credentials
```
#  Watch credentials rotate
kubectl logs -f cartservice-xxx -c vault-agent
# Should see new credentials every hour
```

Commands to watch live CPU and memory usage per pod** across your EKS cluster

### 🔹 Option 1: Using `kubectl top`
First, make sure the **metrics‑server** is installed (most EKS clusters have it by default). Then run:

```bash
kubectl top pods -A --sort-by=memory
```
- Shows CPU (mCPU) and memory (MiB) usage for every pod in every namespace.  
- Add `--sort-by=cpu` if you want to see the top CPU consumers.  
- Run it repeatedly or in `watch` mode:

```bash
watch -n 5 'kubectl top pods -A --sort-by=memory'
```
### 🔹 Option 2: Node‑level view
To see if your **nodes** are close to their limits:

```bash
kubectl top nodes
```
This will show CPU and memory usage vs allocatable per node. On a 3× t3.large cluster you’ll see ~2 vCPU / 8 GiB per node. But we are using t3.xlarge so that our resources and cluster doesn't get slow

### 🔹 Option 3: Quick pod count sanity check
To see how many pods are scheduled and where:

```bash
kubectl get pods -A -o wide | awk '{print $8}' | sort | uniq -c
```

This prints how many pods are running on each node, so you can see if the scheduler is spreading them evenly.
✅ With these three commands you’ll know:
- Which pods are the heaviest (Vault, Istio sidecars, Datadog).  
- Whether your nodes are close to CPU/memory saturation.  
- How evenly pods are distributed across your 3 nodes.

## 🔹 Capacity planning: t3.large vs t3.xlarge

### Your workload estimate
- **Microservices**: 11 total.  
  - 4 with 2 replicas = 8 pods.  
  - 7 with 1 replica = 7 pods.  
  - **Total = 15 pods.**
- **Istio sidecars**: +1 per pod = +15 pods.  
- **Vault**: 3 pods.  
- **ArgoCD**: ~3 pods.  
- **Argo Rollouts**: 1 pod.  
- **Datadog agent**: 1 per node = 3 pods.  
- **System pods** (CoreDNS, CNI, metrics-server, etc.): ~6–8 pods.  

👉 Rough total: ~45–50 pods across the cluster.

### Node sizing
- **t3.large** = 2 vCPU, 8 GiB RAM. With 3 nodes → 6 vCPU, 24 GiB RAM total.  
- **t3.xlarge** = 4 vCPU, 16 GiB RAM. With 3 nodes → 12 vCPU, 48 GiB RAM total.  

### Resource pressure
- Istio sidecars alone will eat ~50–100 MB RAM each → ~1–1.5 GiB cluster‑wide.  
- Vault, ArgoCD, Rollouts, Datadog → ~2–3 GiB.  
- Microservices themselves → ~3–4 GiB.  
- System overhead → ~1 GiB.  

So on **3× t3.large (24 GiB)** you’ll be tight but it will run for a demo.  
On **3× t3.xlarge (48 GiB)** you’ll have breathing room, smoother rollouts, and less risk of OOM evictions.
