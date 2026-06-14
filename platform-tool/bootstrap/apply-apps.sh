#!/usr/bin/env bash
# Apply một hoặc nhiều App-of-Apps vào Argo CD.
# Chạy sau bootstrap.sh — Argo CD phải đang chạy trước.
# Có thể chạy lại bất kỳ lúc nào để thêm App-of-Apps mới.
#
# Cách dùng:
#   ./apply-apps.sh                        # apply tất cả entries trong APPS_LIST
#   ./apply-apps.sh ../apps/app-of-apps.yaml   # apply 1 file cụ thể
set -euo pipefail

# ── CẤU HÌNH — thay trước khi chạy ───────────────────────────────────────
GIT_REPO_URL="https://github.com/YOUR_ORG/bee-infra.git"   # ← thay
GIT_BRANCH="main"
ARGOCD_NAMESPACE="argocd"

# Danh sách App-of-Apps cần apply (theo thứ tự).
# Thêm dòng mới vào đây khi có thêm stack mới.
APPS_LIST=(
  "../apps/app-of-apps.yaml"                              # platform-tool
  "../../open-project/argocd/apps/app-of-apps.yaml"      # OF1 stack
)
# ─────────────────────────────────────────────────────────────────────────

echo "=== Check Argo CD đang chạy ==="
kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" &>/dev/null \
  || { echo "ERROR: Argo CD chưa chạy — hãy chạy bootstrap.sh trước"; exit 1; }

# Nếu truyền argument thì chỉ apply file đó, không dùng APPS_LIST
if [ $# -gt 0 ]; then
  APPS_LIST=("$@")
fi

echo ""
echo "=== Apply App-of-Apps ==="
for APP_FILE in "${APPS_LIST[@]}"; do
  if [ ! -f "$APP_FILE" ]; then
    echo "  SKIP (không tìm thấy): $APP_FILE"
    continue
  fi
  echo "  → $APP_FILE"
  sed "s|https://github.com/dz1194/of1.git|$GIT_REPO_URL|g; s|main|$GIT_BRANCH|g" \
    "$APP_FILE" | kubectl apply -f -
done

echo ""
echo "=== Done — theo dõi sync: ==="
echo "  kubectl get applications -n $ARGOCD_NAMESPACE -w"
echo ""
echo "  Sync-wave order (platform-tool):"
echo "    wave -2 → MetalLB"
echo "    wave -1 → MetalLB IP config, ingress-nginx"
echo "    wave  0 → Longhorn, MinIO"
echo "    wave  1 → Harbor, SonarQube"
echo "    wave  2 → Jenkins"
echo "    wave  3 → Backup jobs"
echo ""
echo "  OF1 stack order (sau platform-tool Healthy):"
echo "    postgresql → memcached → openproject → n8n → grafana"
