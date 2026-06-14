# OF1 — GitOps Deployment Guideline

## Tổng quan

Stack OF1 gồm 5 component, toàn bộ được quản lý bởi ArgoCD theo mô hình **App-of-Apps**:

| Component | Namespace | Mục đích |
|---|---|---|
| PostgreSQL | `openproject` | Database cho OpenProject và n8n |
| Memcached | `openproject` | Cache session và background jobs |
| OpenProject | `openproject` | Project management — source of truth |
| n8n | `n8n` | Automation và intake routing |
| Grafana | `monitoring` | Flow metrics dashboard |

---

## Cấu trúc repo

```
open-project/
├── argocd/
│   ├── projects/
│   │   └── of1-project.yaml        # ArgoCD Project — RBAC, allowed namespaces
│   └── apps/
│       ├── app-of-apps.yaml        # Root app — quản lý tất cả apps bên dưới
│       ├── postgresql.yaml
│       ├── memcached.yaml
│       ├── openproject.yaml
│       ├── n8n.yaml
│       └── grafana.yaml
├── manifests/
│   ├── postgresql/
│   │   ├── statefulset.yaml        # StatefulSet + volumeClaimTemplate
│   │   ├── service.yaml            # Headless service (DNS trực tiếp)
│   │   └── initdb-configmap.yaml   # Tạo user grafana_ro và database n8n
│   ├── memcached/
│   │   └── deployment.yaml         # Deployment + Service (1 file)
│   ├── openproject/
│   │   ├── configmap.yaml          # Env vars (không có secret)
│   │   ├── pvc.yaml                # data (30Gi) + attachments (50Gi)
│   │   ├── deployment-web.yaml     # Web pod — có initContainer migrate
│   │   ├── deployment-worker.yaml  # Background job workers (2 replicas)
│   │   ├── service.yaml
│   │   ├── ingress.yaml
│   │   └── cronjob-grants.yaml     # Grant SELECT cho grafana_ro hàng đêm
│   ├── n8n/
│   │   ├── pvc.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   └── grafana/
│       ├── pvc.yaml
│       ├── configmaps.yaml         # Datasource + dashboard provider + dashboard JSON
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
└── scripts/
    ├── 01-bootstrap-secrets.sh     # Tạo K8s Secrets — chạy một lần đầu
    ├── 02-install-argocd.sh        # Cài ArgoCD + bootstrap App-of-Apps
    ├── 03-post-deploy-verify.sh    # Kiểm tra health toàn stack
    ├── 04-grant-grafana-ro.sh      # Grant SELECT sau migrate
    └── README-deploy-order.md      # Thứ tự triển khai chi tiết
```

---

## Quy tắc thiết kế

### 1. Secrets không nằm trong Git
Tất cả passwords và keys được tạo bởi `scripts/01-bootstrap-secrets.sh` và lưu thẳng vào cluster dưới dạng K8s Secret. Manifests chỉ reference tên secret, không chứa giá trị.

| Secret name | Namespace | Chứa |
|---|---|---|
| `pg-credentials` | openproject | postgres-password, openproject-db-password, grafana-ro-password |
| `openproject-db-secret` | openproject | database-url (full connection string) |
| `openproject-secret` | openproject | secret-key-base |
| `openproject-minio-secret` | openproject | access-key, secret-key (MinIO credentials) |
| `n8n-secrets` | n8n | db-password, encryption-key, openproject-webhook-secret |
| `grafana-secrets` | monitoring | admin-password |

### 2. PVC không bao giờ bị auto-prune
Tất cả PVC có annotation:
```yaml
argocd.argoproj.io/sync-options: Prune=false
```
ArgoCD sẽ không xóa storage kể cả khi manifest bị remove khỏi Git.

### 3. Database không auto-prune
ArgoCD app `of1-postgresql` có `prune: false` — ArgoCD sẽ không xóa StatefulSet kể cả khi bị remove khỏi repo.

### 4. Namespace do ArgoCD tạo
Không có file `namespace.yaml` riêng. Tất cả ArgoCD apps có `CreateNamespace=true` trong syncOptions — ArgoCD tự tạo namespace khi sync.

### 5. Một môi trường, không Kustomize
Không dùng Kustomize overlay vì chỉ có 1 môi trường production. Manifests chứa giá trị thực trực tiếp, đơn giản để đọc và debug.

---

## Thứ tự triển khai lần đầu

```
Bước 1: bash scripts/01-bootstrap-secrets.sh   # Tạo secrets
Bước 2: bash scripts/02-install-argocd.sh       # Cài ArgoCD
Bước 3: argocd repo add <url> ...               # Connect repo
Bước 4: ArgoCD tự sync theo thứ tự             # postgresql → memcached → openproject → n8n → grafana
Bước 5: bash scripts/04-grant-grafana-ro.sh     # Grant DB permissions
Bước 6: bash scripts/03-post-deploy-verify.sh   # Verify
```

Xem chi tiết: [`scripts/README-deploy-order.md`](scripts/README-deploy-order.md)

---

## Cách thay đổi config

### Thay đổi thông thường (image version, resource limits, env var)
1. Sửa file manifest trong `manifests/<component>/`
2. Commit và push
3. ArgoCD tự detect và sync trong vài phút (automated sync)

### Thay đổi secret (password rotation)
```bash
# Ví dụ đổi Grafana admin password
kubectl create secret generic grafana-secrets \
  --namespace monitoring \
  --from-literal=admin-password='NEW_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart để pick up secret mới
kubectl rollout restart deployment grafana -n monitoring
```

### Upgrade OpenProject
1. Thay image tag trong `manifests/openproject/deployment-web.yaml` và `deployment-worker.yaml`
2. Commit và push
3. ArgoCD sync → initContainer `db-migrate` chạy tự động trước khi web pod lên
4. Sau upgrade, chạy lại `scripts/04-grant-grafana-ro.sh` để grant quyền trên bảng mới

### Thêm Grafana dashboard mới
1. Export dashboard JSON từ Grafana UI (Share → Export → Save to file)
2. Thêm vào `manifests/grafana/configmaps.yaml` trong ConfigMap `grafana-dashboard-of1`
3. Commit và push — Grafana tự reload sau 30 giây (không cần restart)

---

## Xử lý sự cố thường gặp

**OpenProject web pod không lên (CrashLoopBackOff):**
```bash
# Xem log initContainer migrate trước
kubectl logs -n openproject deploy/openproject-web -c db-migrate --tail=50
# Xem log web container
kubectl logs -n openproject deploy/openproject-web -c web --tail=50
```

**Grafana không query được PostgreSQL:**
```bash
# Chạy lại grant script
bash scripts/04-grant-grafana-ro.sh
```

**n8n webhook không nhận được event từ OpenProject:**
```bash
# Kiểm tra webhook secret khớp không
kubectl get secret n8n-secrets -n n8n -o jsonpath='{.data.openproject-webhook-secret}' | base64 -d
# So sánh với secret đã config trong OpenProject > Administration > Webhooks
```

**ArgoCD app ở trạng thái OutOfSync mãi không Synced:**
```bash
argocd app diff of1-<component>    # xem diff cụ thể
argocd app sync of1-<component> --force
```

---

## Domains

| Service | URL |
|---|---|
| OpenProject | `https://openproject.bee.vn` |
| n8n | `https://n8n.bee.vn` |
| Grafana | `https://grafana.bee.vn` |
| ArgoCD | `https://argocd.bee.vn` |

TLS được cấp tự động bởi cert-manager + Let's Encrypt (`letsencrypt-prod` ClusterIssuer).
