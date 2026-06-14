#!/usr/bin/env bash
# Apply một hoặc nhiều App-of-Apps vào Argo CD.
# Chạy sau bootstrap.sh — Argo CD phải đang chạy trước.
# Có thể chạy lại bất kỳ lúc nào để thêm App-of-Apps mới.
#
# Cách dùng:
#   ./apply-apps.sh                              # apply tất cả entries trong APPS_LIST
#   ./apply-apps.sh ../apps/app-of-apps.yaml     # apply 1 file cụ thể
#
# Lưu ý: repoURL và targetRevision đọc thẳng từ yaml — không cần sửa script này.
#         Chỉ cần đảm bảo các file yaml đã có đúng repoURL trước khi chạy.
set -euo pipefail

ARGOCD_NAMESPACE="argocd"

# Danh sách App-of-Apps cần apply (theo thứ tự).
# Thêm dòng mới vào đây khi có thêm stack mới.
APPS_LIST=(
  "../apps/app-of-apps.yaml"                              # platform-tool
  "../../open-project/argocd/apps/app-of-apps.yaml"      # OF1 stack
)

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
  kubectl apply -f "$APP_FILE"
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
