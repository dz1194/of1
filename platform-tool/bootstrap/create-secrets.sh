#!/usr/bin/env bash
# Tạo tất cả K8s Secrets trước khi apply App-of-Apps.
# Secrets KHÔNG commit vào Git — chạy script này 1 lần trên cluster.
# Sau khi tạo xong, verify bằng: kubectl get secrets -A | grep -E "minio|harbor|sonar|cmc"
set -euo pipefail

echo "======================================================"
echo "  Platform Secrets Setup"
echo "  Chạy script này SAU khi các namespace đã được tạo."
echo "  Argo CD sẽ tạo namespace tự động khi sync."
echo "  Nếu namespace chưa có: chạy lại sau bước sync đầu."
echo "======================================================"
echo ""

# Helper
create_secret() {
  local name=$1; local ns=$2; shift 2
  kubectl create secret generic "$name" -n "$ns" "$@" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  [OK] secret/$name in $ns"
}

prompt() {
  local var=$1; local msg=$2
  read -rsp "  $msg: " "$var"; echo
}

# ── MinIO ──────────────────────────────────────────────────────────────────
echo "--- MinIO ---"
prompt MINIO_ROOT_USER     "MinIO root username (default: minio-admin)"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minio-admin}"
prompt MINIO_ROOT_PASSWORD "MinIO root password"

kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
create_secret minio-credentials minio \
  --from-literal=rootUser="$MINIO_ROOT_USER" \
  --from-literal=rootPassword="$MINIO_ROOT_PASSWORD"

# ── Harbor ─────────────────────────────────────────────────────────────────
echo ""
echo "--- Harbor ---"
prompt HARBOR_ADMIN_PASS "Harbor admin password"
prompt HARBOR_DB_PASS    "Harbor database password"
prompt HARBOR_SECRET_KEY "Harbor secretKey (chính xác 16 ký tự)"

kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -

create_secret harbor-admin harbor \
  --from-literal=HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASS"

create_secret harbor-database-password harbor \
  --from-literal=POSTGRES_PASSWORD="$HARBOR_DB_PASS"

create_secret harbor-secret-key harbor \
  --from-literal=secretKey="$HARBOR_SECRET_KEY"

# Secret MinIO creds cho Harbor (copy từ MinIO)
create_secret minio-harbor-creds harbor \
  --from-literal=accessKey="$MINIO_ROOT_USER" \
  --from-literal=secretKey="$MINIO_ROOT_PASSWORD"

# ── SonarQube ──────────────────────────────────────────────────────────────
echo ""
echo "--- SonarQube ---"
prompt SONAR_DB_PASS "SonarQube database password"

kubectl create namespace sonarqube --dry-run=client -o yaml | kubectl apply -f -
create_secret sonarqube-db-password sonarqube \
  --from-literal=password="$SONAR_DB_PASS" \
  --from-literal=postgres-password="$SONAR_DB_PASS"

# ── Jenkins ────────────────────────────────────────────────────────────────
echo ""
echo "--- Jenkins ---"
prompt JENKINS_ADMIN_PASS "Jenkins admin password"

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
create_secret jenkins-admin jenkins \
  --from-literal=jenkins-admin-user="admin" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASS"

# ── CMC S3 (Backup target — dùng cho Longhorn + pg_dump CronJobs) ──────────
echo ""
echo "--- CMC S3 Backup Credentials ---"
prompt CMC_ACCESS_KEY  "CMC S3 Access Key ID"
prompt CMC_SECRET_KEY  "CMC S3 Secret Access Key"
CMC_ENDPOINT="${CMC_ENDPOINT:-https://s3.hn-1.cloud.cmctelecom.vn}"

kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

# Longhorn backup secret — BẮT BUỘC có AWS_ENDPOINTS (key đặc biệt cho non-AWS S3)
create_secret longhorn-backup-secret longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID="$CMC_ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$CMC_SECRET_KEY" \
  --from-literal=AWS_ENDPOINTS="$CMC_ENDPOINT"

# pg_dump CronJob secrets (harbor + sonarqube namespace)
for NS in harbor sonarqube; do
  create_secret cmc-s3-credentials "$NS" \
    --from-literal=AWS_ACCESS_KEY_ID="$CMC_ACCESS_KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$CMC_SECRET_KEY" \
    --from-literal=AWS_ENDPOINTS="$CMC_ENDPOINT"
done

echo ""
echo "======================================================"
echo "  Secrets created. Tiếp theo: chạy bootstrap.sh"
echo "======================================================"
