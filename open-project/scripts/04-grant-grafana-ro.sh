#!/usr/bin/env bash
# =============================================================================
# Script 04: Grant SELECT permissions cho grafana_ro sau khi OpenProject migrate
# Chạy một lần sau lần deploy đầu tiên, và sau mỗi major upgrade
# =============================================================================
set -euo pipefail

PG_ROOT_PASSWORD="${PG_ROOT_PASSWORD:-}"

if [[ -z "${PG_ROOT_PASSWORD}" ]]; then
  echo "Lấy password từ secret..."
  PG_ROOT_PASSWORD=$(kubectl get secret pg-credentials -n openproject \
    -o jsonpath='{.data.postgres-password}' | base64 -d)
fi

PG_GRAFANA_RO_PASSWORD=$(kubectl get secret pg-credentials -n openproject \
  -o jsonpath='{.data.grafana-ro-password}' | base64 -d)

echo "==> Grant SELECT on ALL TABLES to grafana_ro..."
kubectl exec -n openproject deploy/openproject-web -- bash -c "
  PGPASSWORD='${PG_ROOT_PASSWORD}' psql \
    -h postgresql.openproject.svc.cluster.local \
    -U postgres \
    -d openproject \
    -c \"GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;\"
  PGPASSWORD='${PG_ROOT_PASSWORD}' psql \
    -h postgresql.openproject.svc.cluster.local \
    -U postgres \
    -d openproject \
    -c \"GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO grafana_ro;\"
"

echo ""
echo "==> Verify grafana_ro có thể query work_packages..."
kubectl exec -n openproject deploy/openproject-web -- bash -c "
  PGPASSWORD='${PG_GRAFANA_RO_PASSWORD}' psql \
    -h postgresql.openproject.svc.cluster.local \
    -U grafana_ro \
    -d openproject \
    -c \"SELECT COUNT(*) FROM work_packages;\"
"

echo "✓ Grafana read-only access ready"
