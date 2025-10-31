🎯 Demo Scenarios for Interview
Scenario 1: Show Zero-Downtime Deployment
```
# Terminal 1: Watch rollout in real-time
kubectl argo rollouts get rollout cartservice --watch
# Terminal 2: Monitor service with continuous requests
while true; do curl -s http://FRONTEND_LB/cart | grep -o "v[0-9]"; sleep 1; done
# Terminal 3: Trigger deployment
git commit -m "Update cartservice to v2"
git push origin main
# Result: No 5xx errors, gradual version transition
```

Scenario 2: Show Automatic Vault Rotation
```
# Terminal 1: Watch DB connections
kubectl logs -f cartservice-xxx | grep "DB connection"
# Terminal 2: Check current credentials
kubectl exec -it cartservice-xxx -c vault-agent -- cat /vault/secrets/db-creds
# Wait 1 hour, check again - credentials have changed!
# Application continues running without restart
```

Scenario 3: Show Istio Traffic Management
```
# Open Kiali dashboard
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Generate traffic
kubectl run load-generator --image=busybox --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://frontend; done"
# Show in Kiali:
# - Service topology
# - Traffic flow percentages
# - mTLS badges (locked icons)
# - Request rates and latencies
```

Scenario 4: Show Monitoring & Alerting
```
# Trigger high CPU alert
kubectl run cpu-stress --image=polinux/stress --restart=Never -- stress --cpu 2
# Within 2 minutes:
# - Datadog monitor triggers
# - Slack receives alert with pod name, CPU %, and dashboard link
# - Show Datadog dashboard with spike
# Resolve
kubectl delete pod cpu-stress
# Slack receives "Recovered" notification
```
```
