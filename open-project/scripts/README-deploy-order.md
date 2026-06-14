# Thứ tự triển khai

## Bước 0 — Chuẩn bị repo

```bash
# Clone về, thay REPO_URL và domain trong argocd/apps/*.yaml
# Domain mặc định đã là bee.vn — chỉ cần thay YOUR_ORG
sed -i 's|YOUR_ORG|ten-org-github-cua-ban|g' argocd/apps/*.yaml

git add -A && git commit -m "chore: set repo URL"
git push
```

## Bước 1 — Tạo Secrets

```bash
export PG_ROOT_PASSWORD="..."
export PG_OP_PASSWORD="..."
export PG_GRAFANA_RO_PASSWORD="..."
export PG_N8N_PASSWORD="..."
export GRAFANA_ADMIN_PASSWORD="..."

bash scripts/01-bootstrap-secrets.sh
```

Lưu output vào password manager ngay.

## Bước 2 — Cài ArgoCD

```bash
export REPO_URL="https://github.com/YOUR_ORG/open-project.git"
export ARGOCD_DOMAIN="argocd.bee.vn"

bash scripts/02-install-argocd.sh
```

## Bước 3 — Connect repo

```bash
argocd login argocd.bee.vn --username admin
argocd repo add https://github.com/YOUR_ORG/open-project.git \
  --username git \
  --password YOUR_GITHUB_PAT
```

## Bước 4 — ArgoCD sync tự động

Theo dõi trên UI: [https://argocd.bee.vn](https://argocd.bee.vn)

Thứ tự sync (manual nếu muốn kiểm soát):

```bash
argocd app sync of1-postgresql  && argocd app wait of1-postgresql  --health
argocd app sync of1-memcached   && argocd app wait of1-memcached   --health
argocd app sync of1-openproject && argocd app wait of1-openproject --health
argocd app sync of1-n8n
argocd app sync of1-grafana
```

## Bước 5 — Grant Grafana permissions

```bash
bash scripts/04-grant-grafana-ro.sh
```

## Bước 6 — Verify

```bash
bash scripts/03-post-deploy-verify.sh
```
