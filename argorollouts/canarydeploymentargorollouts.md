# ========================================
# HOW TO USE: Canary Deployment Flow
# ========================================
This is a demo readme file for argorollouts canary deployment 
************IMP********************
The 2 files cartservice_argorollouts.yaml and cartservice-virtualservice.yaml need to be present in K8S-manifests folder in order for ARGOCD to sync the changes in EKS CLUSTER.
So after testing normal deployment make sure to delete the old cartservicedep.yaml and replacing it with these 2 files in the K8S-manifests folder

# ========================================
# INTEGRATION WITH YOUR EXISTING SETUP
# ========================================

# 1. Delete old cartservicedep.yml
```
kubectl delete -f cartservicedep.yml
```
OR
Directly remove from the github and before that copy and save that somewhere else safely after testing normal deployment with ARGOCD

# 2. Update GitOps Repo Structure:

```
k8s-manifests/
├── cartservice-rollout.yaml          # Use Rollout instead of Deployment
├── cartservice-virtualservice.yaml   # Add VirtualService
├── checkoutservice.yaml              # Keep as Deployment (or convert)
├── productcatalogservice.yaml        # Keep as Deployment
├── paymentservice.yaml               # Keep as Deployment
└── ... (other services)
```

# 3. ArgoCD Application (NO CHANGES NEEDED)
#    - ArgoCD supports Rollouts natively
#    - Just syncs Rollout objects like Deployments

# 4. Istio (MUST BE INSTALLED FIRST)
#    - Argo Rollouts needs Istio for traffic splitting
#    - Install Istio before testing canary

# SCENARIO: You made changes to cartservice code

# Step 1: Build and push new Docker image (Jenkins CI)
# I have already done this so no need to worry you can use my existing v1 and v2 infact all of the images from my manifests
```
docker build -t harshakoppu945/cartservice:v2 .
docker push harshakoppu945/cartservice:v2
```
# Step 2: Update Rollout image in Git
# Edit k8s-manifests/cartservice-rollout.yaml:
#   image: harshakoppu945/cartservice:v2  # Changed from v1 to v2

# Step 3: Commit and push
```
git add k8s-manifests/cartservice-rollout.yaml
git commit -m "Update cartservice to v2"
git push origin main
```
   OR
To trigger a canary update directly:
```
kubectl argo rollouts set image cartservice server=harshakoppu945/cartservice:v2
```


 Step 4: ArgoCD detects change and starts rollout
# Watch the rollout progress:
```
kubectl argo rollouts get rollout cartservice --watch

# You'll see:
# ├──# revision:2
# │  ├──⧉ cartservice-v2-abc123 (canary)
# │  │  ├──□ cartservice-v2-abc123-1 (Running) - 10% traffic
# │  └──α cartservice-v2 pause (2m)
# └──# revision:1
#    └──⧉ cartservice-v1-xyz789 (stable)
#       ├──□ cartservice-v1-xyz789-1 (Running) - 90% traffic
#       ├──□ cartservice-v1-xyz789-2 (Running)
#       └──□ cartservice-v1-xyz789-3 (Running)
```

# Step 5: Monitor canary
# Check Kiali dashboard to see traffic split
# Check Datadog for error rates
# Check argorollouts dashboard either by portforwarding or loadbalancer or by installing kubectl plugin by following the steps mentioned in other .md files 

# Step 6a: If canary is good (automatic)
# Rollout continues through steps automatically
# Eventually 100% traffic goes to v2
# Old v1 pods are terminated
```
kubectl logs <cartservice-pod-name> -f to see the log we changed or wrote in CartService.cs for v2 docker image
```

# Step 6b: If canary has issues (manual rollback)
kubectl argo rollouts abort cartservice
kubectl argo rollouts undo cartservice
# Traffic immediately reverts to v1

# Step 7: Promote manually (optional)
kubectl argo rollouts promote cartservice
