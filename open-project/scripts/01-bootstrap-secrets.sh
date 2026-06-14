#!/usr/bin/env bash
# =============================================================================
# Script 01: Tạo tất cả Kubernetes Secrets trước khi deploy
# Chạy MỘT LẦN trước khi apply ArgoCD apps
# Yêu cầu: kubectl đã cấu hình đúng cluster
# =============================================================================
set -euo pipefail

# ---------- CẤU HÌNH — SỬA CÁC GIÁ TRỊ NÀY ----------
DOMAIN_OPENPROJECT="openproject.bee.vn"
DOMAIN_N8N="n8n.bee.vn"
DOMAIN_GRAFANA="grafana.bee.vn"

# Passwords — thay thế bằng giá trị thực hoặc dùng vault/SOPS
PG_ROOT_PASSWORD="${PG_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
PG_OP_PASSWORD="${PG_OP_PASSWORD:-$(openssl rand -base64 24)}"
PG_GRAFANA_RO_PASSWORD="${PG_GRAFANA_RO_PASSWORD:-$(openssl rand -base64 24)}"
PG_N8N_PASSWORD="${PG_N8N_PASSWORD:-$(openssl rand -base64 24)}"

OP_SECRET_KEY="${OP_SECRET_KEY:-$(openssl rand -hex 64)}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
N8N_WEBHOOK_SECRET="${N8N_WEBHOOK_SECRET:-$(openssl rand -hex 32)}"
# Teams Incoming Webhook URL — lấy từ Teams channel > Connectors > Incoming Webhook
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:?Cần set TEAMS_WEBHOOK_URL}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 20)}"

# MinIO credentials — phải set thủ công (lấy từ MinIO console)
# Bucket cần tạo trước: openproject-attachments (xem hướng dẫn bên dưới)
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:?Cần set MINIO_ACCESS_KEY}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:?Cần set MINIO_SECRET_KEY}"
# -------------------------------------------------------

echo "==> Tạo namespaces..."
kubectl create namespace openproject --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace n8n         --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> [openproject] pg-credentials..."
kubectl create secret generic pg-credentials \
  --namespace openproject \
  --from-literal=postgres-password="${PG_ROOT_PASSWORD}" \
  --from-literal=openproject-db-password="${PG_OP_PASSWORD}" \
  --from-literal=grafana-ro-password="${PG_GRAFANA_RO_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [openproject] openproject-db-secret (DATABASE_URL)..."
DATABASE_URL="postgresql://openproject:${PG_OP_PASSWORD}@postgresql.openproject.svc.cluster.local/openproject"
kubectl create secret generic openproject-db-secret \
  --namespace openproject \
  --from-literal=database-url="${DATABASE_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [openproject] openproject-secret (SECRET_KEY_BASE)..."
kubectl create secret generic openproject-secret \
  --namespace openproject \
  --from-literal=secret-key-base="${OP_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> [n8n] n8n-secrets..."
kubectl create secret generic n8n-secrets \
  --namespace n8n \
  --from-literal=db-password="${PG_N8N_PASSWORD}" \
  --from-literal=encryption-key="${N8N_ENCRYPTION_KEY}" \
  --from-literal=openproject-webhook-secret="${N8N_WEBHOOK_SECRET}" \
  --from-literal=teams-webhook-url="${TEAMS_WEBHOOK_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> [monitoring] grafana-secrets..."
kubectl create secret generic grafana-secrets \
  --namespace monitoring \
  --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> [openproject] openproject-minio-secret..."
kubectl create secret generic openproject-minio-secret \
  --namespace openproject \
  --from-literal=access-key="${MINIO_ACCESS_KEY}" \
  --from-literal=secret-key="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "========================================================"
echo "✓ Secrets tạo xong. LƯU LẠI các giá trị sau:"
echo "========================================================"
echo "PG Root Password:     ${PG_ROOT_PASSWORD}"
echo "PG OpenProject Pass:  ${PG_OP_PASSWORD}"
echo "PG Grafana RO Pass:   ${PG_GRAFANA_RO_PASSWORD}"
echo "PG n8n Password:      ${PG_N8N_PASSWORD}"
echo "OP Secret Key:        (ẩn — đã lưu vào secret)"
echo "n8n Encryption Key:   (ẩn — đã lưu vào secret)"
echo "n8n Webhook Secret:   ${N8N_WEBHOOK_SECRET}  ← dùng khi cấu hình webhook trong OpenProject"
echo "Grafana Admin Pass:   ${GRAFANA_ADMIN_PASSWORD}"
echo "MinIO Access Key:     ${MINIO_ACCESS_KEY}"
echo ""
echo "⚠  Lưu ngay vào password manager / vault trước khi đóng terminal!"
echo ""
echo "📦 MinIO — tạo bucket trước khi sync ArgoCD:"
echo "   mc alias set local http://minio.minio.svc.cluster.local:9000 \${MINIO_ACCESS_KEY} \${MINIO_SECRET_KEY}"
echo "   mc mb local/openproject-attachments"
echo "   mc anonymous set none local/openproject-attachments"
