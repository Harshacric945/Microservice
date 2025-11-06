#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0

check() {
  echo -e "${YELLOW}Checking: $1${NC}"
  if eval "$2"; then
    echo -e "${GREEN}✅ PASS${NC}\n"
  else
    echo -e "${RED}❌ FAIL${NC}\n"
    FAILED=1
  fi
}

echo "=========================================="
echo "    PRE-FLIGHT DEPLOYMENT CHECKS"
echo "=========================================="
echo ""

check "Vault pods running" \
  "kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[*].status.phase}' | grep -q 'Running'"

check "Vault unsealed" \
  "kubectl exec -n vault vault-0 -- vault status | grep -q 'Sealed.*false'"

check "Vault Agent Injector running" \
  "kubectl get pods -n vault -l app.kubernetes.io/name=vault-agent-injector -o jsonpath='{.items[0].status.containerStatuses[0].ready}' | grep -q 'true'"

check "Vault webhook configured" \
  "kubectl get mutatingwebhookconfigurations vault-agent-injector-cfg &>/dev/null"

check "Istio running" \
  "kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

check "Istio injection enabled" \
  "kubectl get namespace default -o jsonpath='{.metadata.labels.istio-injection}' | grep -q 'enabled'"

check "Database roles exist" \
  "kubectl exec -n vault vault-0 -- vault list database/roles | grep -q 'cartservice-role'"

check "Kubernetes auth roles exist" \
  "kubectl exec -n vault vault-0 -- vault list auth/kubernetes/role | grep -q 'cartservice-role'"

check "Service accounts exist" \
  "kubectl get sa -n default cartservice-sa checkoutservice-sa paymentservice-sa productcatalogservice-sa &>/dev/null"

echo ""
echo "=========================================="
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}✅ ALL CHECKS PASSED - SAFE TO DEPLOY${NC}"
  echo "=========================================="
  exit 0
else
  echo -e "${RED}❌ SOME CHECKS FAILED - DO NOT DEPLOY${NC}"
  echo "=========================================="
  exit 1
fi
