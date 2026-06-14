#!/usr/bin/env bash
# Bootstrap script — chạy 1 lần duy nhất.
# Sau bước này, MỌI thay đổi đều qua Git → Argo CD tự sync.
#
# Yêu cầu:
#   - node-setup.sh đã chạy trên mọi node (open-iscsi, vm.max_map_count)
#   - create-secrets.sh đã chạy
#   - MetalLB IP pool (helm-values/metallb/templates/ip-pool.yaml) đã điền IP thật
#   - Git repo đã push và GIT_REPO_URL bên dưới đã được điền đúng
set -euo pipefail

# ── CẤU HÌNH — thay trước khi chạy ───────────────────────────────────────
GIT_REPO_URL="https://github.com/YOUR_ORG/platform-tool.git"   # ← thay
GIT_BRANCH="main"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="7.x"   # helm chart version của argo/argo-cd
# ─────────────────────────────────────────────────────────────────────────

echo "=== [1/5] Check prerequisites ==="
command -v helm    &>/dev/null || { echo "helm not found"; exit 1; }
command -v kubectl &>/dev/null || { echo "kubectl not found"; exit 1; }
kubectl cluster-info &>/dev/null || { echo "kubectl cannot reach cluster"; exit 1; }

DEFAULT_SC=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
[ -n "$DEFAULT_SC" ] && echo "  Default SC: $DEFAULT_SC" \
  || echo "  WARN: No default StorageClass — Longhorn sẽ set sau khi sync wave 0"

echo ""
echo "=== [2/5] Add Helm repos ==="
helm repo add argo          https://argoproj.github.io/argo-helm
helm repo add metallb       https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn      https://charts.longhorn.io
helm repo add minio         https://charts.min.io
helm repo add harbor        https://helm.goharbor.io
helm repo add sonarqube     https://SonarSource.github.io/helm-chart-sonarqube
helm repo add jenkins       https://charts.jenkins.io
helm repo update

echo ""
echo "=== [3/5] Install Argo CD (imperative — 1 lần duy nhất) ==="
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --version "$ARGOCD_VERSION" \
  -f argocd-values.yaml \
  --wait --timeout 10m

echo ""
echo "=== [4/5] Apply App-of-Apps (root Application) ==="
# Patch GIT_REPO_URL vào app-of-apps trước khi apply
sed "s|YOUR_GIT_REPO_URL|$GIT_REPO_URL|g; s|YOUR_GIT_BRANCH|$GIT_BRANCH|g" \
  ../apps/app-of-apps.yaml | kubectl apply -f -

echo ""
echo "=== [5/5] Done — Argo CD sẽ tự sync phần còn lại ==="
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n "$ARGOCD_NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)
ARGOCD_HOST=$(kubectl get ingress -n "$ARGOCD_NAMESPACE" \
  -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "argocd.example.local")

echo ""
echo "  Argo CD UI : https://$ARGOCD_HOST"
echo "  Username   : admin"
echo "  Password   : $ARGOCD_PASS  (đổi ngay sau khi login)"
echo ""
echo "  Theo dõi sync tiến trình:"
echo "    kubectl get applications -n $ARGOCD_NAMESPACE -w"
echo ""
echo "  Sync-wave order:"
echo "    wave -2 → MetalLB"
echo "    wave -1 → MetalLB IP config, ingress-nginx  (cho wave -2 Healthy)"
echo "    wave  0 → Longhorn, MinIO                   (cho wave -1 Healthy)"
echo "    wave  1 → Harbor, SonarQube                 (cho wave  0 Healthy)"
echo "    wave  2 → Jenkins                           (cho wave  1 Healthy)"
echo "    wave  3 → Backup jobs                       (cho wave  2 Healthy)"
