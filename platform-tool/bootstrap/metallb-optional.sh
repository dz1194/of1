#!/usr/bin/env bash
# [OPTIONAL] Cài MetalLB — chỉ cần cho on-prem.
# Trên cloud (AWS/GCP/Azure/CMC Cloud): BỎ QUA script này,
# cloud provider tự cấp External IP cho LoadBalancer Service.
#
# Chạy script này TRƯỚC bootstrap.sh nếu cần MetalLB.
set -euo pipefail

echo "=== [1/3] Install MetalLB ==="
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --version "0.14.x" \
  -f ../helm-values/metallb/values.yaml \
  --wait --timeout 5m

echo "=== [2/3] Verify MetalLB pods ==="
kubectl get pods -n metallb-system

echo "=== [3/3] Apply IP pool ==="
echo ""
echo "Trước khi apply: mở file helm-values/metallb/templates/ip-pool.yaml"
echo "và điền dải IP phù hợp với mạng của bạn (xem hướng dẫn bên trong file)."
echo ""
read -rp "Đã điền IP pool chưa? (y/N) " CONFIRM
[ "$CONFIRM" = "y" ] || { echo "Hãy chỉnh ip-pool.yaml rồi chạy lại."; exit 1; }

kubectl apply -f ../helm-values/metallb/templates/ip-pool.yaml

echo ""
echo "=== MetalLB installed. Tiếp tục chạy bootstrap.sh ==="
