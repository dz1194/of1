#!/usr/bin/env bash
# =============================================================================
# Script 03: Verify stack sau khi ArgoCD sync xong
# =============================================================================
set -euo pipefail

DOMAIN_OPENPROJECT="${DOMAIN_OPENPROJECT:-openproject.bee.vn}"
DOMAIN_N8N="${DOMAIN_N8N:-n8n.bee.vn}"
DOMAIN_GRAFANA="${DOMAIN_GRAFANA:-grafana.bee.vn}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

check() {
  local label="$1"; local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo -e "${GREEN}✓${NC} ${label}"
    ((PASS++))
  else
    echo -e "${RED}✗${NC} ${label}"
    ((FAIL++))
  fi
}

warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

echo "========================================"
echo " OF1 Stack — Post-Deploy Verification"
echo "========================================"
echo ""

echo "--- Pods ---"
check "PostgreSQL running" \
  "kubectl get pod -n openproject -l app.kubernetes.io/name=postgresql --field-selector=status.phase=Running | grep -q Running"

check "Memcached running" \
  "kubectl get pod -n openproject -l app=memcached --field-selector=status.phase=Running | grep -q Running"

check "OpenProject web running" \
  "kubectl get pod -n openproject -l app=openproject,component=web --field-selector=status.phase=Running | grep -q Running"

check "OpenProject worker running" \
  "kubectl get pod -n openproject -l app=openproject,component=worker --field-selector=status.phase=Running | grep -q Running"

check "n8n running" \
  "kubectl get pod -n n8n -l app=n8n --field-selector=status.phase=Running | grep -q Running"

check "Grafana running" \
  "kubectl get pod -n monitoring -l app=grafana --field-selector=status.phase=Running | grep -q Running"

echo ""
echo "--- Services ---"
check "OpenProject service" \
  "kubectl get svc openproject -n openproject"
check "n8n service" \
  "kubectl get svc n8n -n n8n"
check "Grafana service" \
  "kubectl get svc grafana -n monitoring"

echo ""
echo "--- HTTP Health ---"
check "OpenProject health_check" \
  "curl -sf --max-time 10 https://${DOMAIN_OPENPROJECT}/health_check"
check "n8n healthz" \
  "curl -sf --max-time 10 https://${DOMAIN_N8N}/healthz"
check "Grafana api health" \
  "curl -sf --max-time 10 https://${DOMAIN_GRAFANA}/api/health"

echo ""
echo "--- Database connectivity ---"
check "PostgreSQL port reachable from openproject ns" \
  "kubectl exec -n openproject deploy/openproject-web -- nc -zv postgresql 5432"

echo ""
echo "--- Secrets ---"
check "pg-credentials exists" \
  "kubectl get secret pg-credentials -n openproject"
check "openproject-secret exists" \
  "kubectl get secret openproject-secret -n openproject"
check "n8n-secrets exists" \
  "kubectl get secret n8n-secrets -n n8n"
check "grafana-secrets exists" \
  "kubectl get secret grafana-secrets -n monitoring"

echo ""
echo "--- ArgoCD sync status ---"
for app in of1-postgresql of1-memcached of1-openproject of1-n8n of1-grafana; do
  STATUS=$(kubectl get application "${app}" -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
  HEALTH=$(kubectl get application "${app}" -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  if [[ "${STATUS}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
    echo -e "${GREEN}✓${NC} ${app}: ${STATUS} / ${HEALTH}"
    ((PASS++))
  else
    echo -e "${RED}✗${NC} ${app}: ${STATUS} / ${HEALTH}"
    ((FAIL++))
  fi
done

echo ""
echo "========================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [[ ${FAIL} -gt 0 ]]; then
  echo ""
  warn "Kiểm tra logs: kubectl logs -n <namespace> deploy/<name> --tail=50"
  exit 1
fi
