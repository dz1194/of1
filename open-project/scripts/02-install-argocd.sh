#!/usr/bin/env bash
# =============================================================================
# Script 02: Cài ArgoCD và bootstrap App-of-Apps
# Chạy SAU script 01
# =============================================================================
set -euo pipefail

ARGOCD_VERSION="v2.11.3"   # pin version
REPO_URL="${REPO_URL:-https://github.com/YOUR_ORG/open-project.git}"
ARGOCD_DOMAIN="${ARGOCD_DOMAIN:-argocd.bee.vn}"
ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-}"

echo "==> Tạo namespace argocd..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "==> Cài ArgoCD ${ARGOCD_VERSION}..."
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Chờ ArgoCD CRDs và pods sẵn sàng..."
kubectl wait --for=condition=established \
  crd/applications.argoproj.io \
  crd/appprojects.argoproj.io \
  --timeout=120s

kubectl rollout status deployment argocd-server -n argocd --timeout=300s
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=300s

echo "==> Expose ArgoCD qua Ingress..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["${ARGOCD_DOMAIN}"]
      secretName: argocd-tls
  rules:
    - host: "${ARGOCD_DOMAIN}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF

# Set admin password nếu được cung cấp
if [[ -n "${ARGOCD_ADMIN_PASSWORD}" ]]; then
  echo "==> Set ArgoCD admin password..."
  BCRYPT_HASH=$(htpasswd -bnBC 10 "" "${ARGOCD_ADMIN_PASSWORD}" | tr -d ':\n')
  kubectl -n argocd patch secret argocd-secret \
    -p "{\"stringData\": {\"admin.password\": \"${BCRYPT_HASH}\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
fi

echo ""
echo "==> Add repo đến ArgoCD (qua CLI)..."
echo "    Chạy lệnh sau sau khi login:"
echo ""
echo "    argocd login ${ARGOCD_DOMAIN}"
echo "    argocd repo add ${REPO_URL} \\"
echo "      --username git \\"
echo "      --password YOUR_GITHUB_TOKEN \\"
echo "      --name of1-repo"
echo ""

echo "==> Tạo ArgoCD Project..."
kubectl apply -f argocd/projects/of1-project.yaml

echo "==> Bootstrap App-of-Apps..."
# Thay REPO_URL trong file trước khi apply
sed "s|https://github.com/YOUR_ORG/open-project.git|${REPO_URL}|g" \
  argocd/apps/app-of-apps.yaml | kubectl apply -f -

echo ""
echo "========================================================"
echo "✓ ArgoCD đã bootstrap xong!"
echo "  UI: https://${ARGOCD_DOMAIN}"
echo "  Default admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '(đã set custom password)')"
echo "========================================================"
