#!/usr/bin/env bash
# =============================================================================
# create-secrets.sh — Tạo tất cả Kubernetes Secrets cho OF1 Platform
# Chạy TRƯỚC khi apply root-app.yaml
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Màu terminal
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# -----------------------------------------------------------------------------
# Kiểm tra kubectl
# -----------------------------------------------------------------------------
command -v kubectl &>/dev/null || error "kubectl không tìm thấy. Cài kubectl trước."
kubectl cluster-info &>/dev/null  || error "Không kết nối được cluster. Kiểm tra KUBECONFIG."

echo ""
echo "============================================================"
echo "  OF1 Platform — Tạo Kubernetes Secrets"
echo "============================================================"
echo ""

# =============================================================================
# Hàm tiện ích
# =============================================================================

# Tạo namespace nếu chưa có
ensure_namespace() {
  local ns=$1
  if ! kubectl get namespace "$ns" &>/dev/null; then
    kubectl create namespace "$ns"
    info "Đã tạo namespace: $ns"
  fi
}

# Tạo secret, skip nếu đã tồn tại (không ghi đè)
create_secret() {
  local name=$1
  local ns=$2
  shift 2
  local args=("$@")

  if kubectl get secret "$name" -n "$ns" &>/dev/null; then
    warn "Secret '$name' trong namespace '$ns' đã tồn tại — bỏ qua."
    return
  fi

  kubectl create secret generic "$name" -n "$ns" "${args[@]}"
  success "Đã tạo secret: $name ($ns)"
}

# =============================================================================
# INPUT: Mật khẩu cho từng service
# Nếu để trống → script tự sinh ngẫu nhiên
# =============================================================================

echo "Nhập mật khẩu cho từng service (Enter để tự sinh ngẫu nhiên):"
echo ""

prompt_password() {
  local label=$1
  local varname=$2
  local generated
  generated=$(openssl rand -base64 20 | tr -d '/+=\n' | head -c 24)

  read -rsp "  ${label} [tự sinh nếu bỏ trống]: " input
  echo ""
  if [[ -z "$input" ]]; then
    eval "$varname='$generated'"
    info "${label}: tự sinh → (đã lưu vào file secrets-output.txt)"
  else
    eval "$varname='$input'"
  fi
}

prompt_password "MinIO root password"                MINIO_PASSWORD
prompt_password "Harbor admin password"              HARBOR_ADMIN_PASSWORD
prompt_password "Harbor DB password"                 HARBOR_DB_PASSWORD
prompt_password "Harbor secret key (16 ký tự)"      HARBOR_SECRET_KEY
prompt_password "Jenkins admin password"             JENKINS_PASSWORD
prompt_password "OpenProject DB password"            OP_DB_PASSWORD
prompt_password "Grafana admin password"             GRAFANA_PASSWORD
prompt_password "Grafana RO password (PostgreSQL)"   GRAFANA_RO_PASSWORD

# Các giá trị tự sinh (không cần user nhập)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
OP_SECRET_KEY_BASE=$(openssl rand -hex 64)

echo ""
echo "------------------------------------------------------------"
echo "  Lưu mật khẩu ra file secrets-output.txt (KHÔNG commit file này!)"
echo "------------------------------------------------------------"

OUTPUT_FILE="$(dirname "$0")/secrets-output.txt"
cat > "$OUTPUT_FILE" <<EOF
# OF1 Platform Secrets — $(date '+%Y-%m-%d %H:%M:%S')
# !! KHÔNG commit file này lên Git !!

MINIO_PASSWORD=$MINIO_PASSWORD
HARBOR_ADMIN_PASSWORD=$HARBOR_ADMIN_PASSWORD
HARBOR_DB_PASSWORD=$HARBOR_DB_PASSWORD
HARBOR_SECRET_KEY=$HARBOR_SECRET_KEY
JENKINS_PASSWORD=$JENKINS_PASSWORD
OP_DB_PASSWORD=$OP_DB_PASSWORD
OP_SECRET_KEY_BASE=$OP_SECRET_KEY_BASE
GRAFANA_PASSWORD=$GRAFANA_PASSWORD
GRAFANA_RO_PASSWORD=$GRAFANA_RO_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
EOF

chmod 600 "$OUTPUT_FILE"
success "Đã lưu ra $OUTPUT_FILE"
echo ""

# =============================================================================
# Tạo Namespaces
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Namespaces..."
echo "------------------------------------------------------------"

for ns in minio harbor sonarqube jenkins openproject n8n grafana; do
  ensure_namespace "$ns"
done
echo ""

# =============================================================================
# MINIO
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Secrets: MinIO"
echo "------------------------------------------------------------"

create_secret minio-credentials minio \
  --from-literal=rootUser=minioadmin \
  --from-literal=rootPassword="$MINIO_PASSWORD"

echo ""

# =============================================================================
# HARBOR
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Secrets: Harbor"
echo "------------------------------------------------------------"

create_secret harbor-admin-secret harbor \
  --from-literal=HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD"

create_secret harbor-secret-key harbor \
  --from-literal=secretKey="$HARBOR_SECRET_KEY"

create_secret harbor-db-secret harbor \
  --from-literal=POSTGRES_PASSWORD="$HARBOR_DB_PASSWORD"

# Harbor dùng cùng credentials MinIO
create_secret harbor-s3-secret harbor \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=minioadmin \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$MINIO_PASSWORD"

echo ""

# =============================================================================
# JENKINS
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Secrets: Jenkins"
echo "------------------------------------------------------------"

create_secret jenkins-admin-secret jenkins \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="$JENKINS_PASSWORD"

echo ""

# =============================================================================
# OPENPROJECT
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Secrets: OpenProject"
echo "------------------------------------------------------------"

create_secret openproject-postgresql openproject \
  --from-literal=postgres-password="$OP_DB_PASSWORD" \
  --from-literal=password="$OP_DB_PASSWORD"

create_secret openproject-env-secret openproject \
  --from-literal=DATABASE_URL="postgres://postgres:${OP_DB_PASSWORD}@openproject-postgresql/openproject?pool=20" \
  --from-literal=OPENPROJECT_SECRET__KEY__BASE="$OP_SECRET_KEY_BASE"

echo ""

# =============================================================================
# N8N
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Secrets: n8n"
echo "------------------------------------------------------------"

create_secret n8n-secret n8n \
  --from-literal=N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY"

echo ""

# =============================================================================
# GRAFANA
# =============================================================================
echo "------------------------------------------------------------"
info "Tạo Secrets: Grafana"
echo "------------------------------------------------------------"

create_secret grafana-admin-secret grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_PASSWORD"

create_secret grafana-datasource-secret grafana \
  --from-literal=password="$GRAFANA_RO_PASSWORD"

echo ""

# =============================================================================
# TỔNG KẾT
# =============================================================================
echo "============================================================"
success "Tất cả Secrets đã được tạo thành công!"
echo "============================================================"
echo ""
echo "Bước tiếp theo:"
echo "  1. Kiểm tra: kubectl get secrets -A | grep -v kubernetes.io"
echo "  2. Deploy: kubectl apply -f gitops/apps/root-app.yaml"
echo ""
echo "  Lưu ý sau khi deploy:"
echo "  - Tạo user grafana_ro trên PostgreSQL OpenProject (xem DEPLOYMENT-GUIDE.md §7.1)"
echo "  - Cập nhật grafana-datasource-secret với đúng password grafana_ro"
echo "============================================================"
