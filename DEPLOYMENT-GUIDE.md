# Bee DevOps — Hướng dẫn Triển khai Tổng hợp

> **Nguyên tắc:** Git là source of truth. Mọi thay đổi config → sửa file → `git push` → Argo CD tự sync.
> Không bao giờ chạy `helm upgrade` hay `kubectl apply` tay (trừ Secrets và bootstrap).

---

## Mục lục

1. [Kiến trúc tổng thể](#1-kiến-trúc-tổng-thể)
2. [Resource requirements](#2-resource-requirements)
3. [Cấu trúc repo](#3-cấu-trúc-repo)
4. [Chuẩn bị trước khi triển khai](#4-chuẩn-bị-trước-khi-triển-khai)
5. [Triển khai Platform Tool](#5-triển-khai-platform-tool)
6. [Triển khai OF1 Stack](#6-triển-khai-of1-stack)
7. [Vận hành hàng ngày](#7-vận-hành-hàng-ngày)
8. [Troubleshooting](#8-troubleshooting)
9. [URLs & Domains](#9-urls--domains)

---

## 1. Kiến trúc tổng thể

Hệ thống gồm 2 lớp — triển khai theo thứ tự từ dưới lên:

```text
┌─────────────────────────────────────────────────────────────────────┐
│  NGUỒN YÊU CẦU                                                      │
│  Tập đoàn (Bee) · Domain Owners · Công ty thành viên · Nội bộ      │
└────────────┬──────────────────┬──────────────────┬───────────────────┘
             │ Email            │ Web Form (n8n)   │ Direct (account)
             ▼                  ▼                  ▼
┌──────────────── LAYER 2 — OF1 STACK (open-project/) ───────────────┐
│  OpenProject Community — project management, source of truth        │
│  n8n            — automation, intake routing, webhooks              │
│  Grafana        — flow metrics dashboards                           │
│  PostgreSQL     — database cho OpenProject + n8n                    │
│  Memcached      — cache session và background jobs                  │
└─────────────────────────────────────────────────────────────────────┘
             ↕ chạy trên
┌──────────────── LAYER 1 — PLATFORM TOOL (platform-tool/) ──────────┐
│  Argo CD        — GitOps controller                                 │
│  Longhorn       — block storage (default StorageClass)              │
│  MinIO          — object storage (S3-compatible, Harbor backend)    │
│  Harbor         — container registry                                │
│  SonarQube      — code quality                                      │
│  Jenkins        — CI/CD                                             │
│  Backup         — Longhorn RecurringJobs + pg_dump → CMC S3        │
└─────────────────────────────────────────────────────────────────────┘
             ↕ off-site backup
┌──────────────── CMC S3 ─────────────────────────────────────────────┐
│  endpoint: https://s3.hn-1.cloud.cmctelecom.vn                     │
│  bucket: platform-backup  (versioning bật)                         │
└─────────────────────────────────────────────────────────────────────┘
```

**Sync-wave platform-tool** — Argo CD chỉ chuyển sang wave tiếp theo khi wave trước **Healthy**:

```text
bootstrap.sh  →  Argo CD running  →  apply-apps.sh
                                           │
                                           ▼
                     wave -1  ingress-nginx
                     wave  0  Longhorn · MinIO
                     wave  1  Harbor · SonarQube
                     wave  2  Jenkins
                     wave  3  Backup (CronJob + RecurringJob)
```

**Sync-wave OF1 stack** (apply sau khi platform-tool Healthy):

```text
apply-apps.sh (OF1)  →  ArgoCD tự sync theo thứ tự:
postgresql  →  memcached  →  openproject  →  n8n  →  grafana
```

---

## 2. Resource Requirements

> Starting point — tune sau khi chạy thật bằng `kubectl top pod`.

### Layer 1 — Platform Tool

| Tool | CPU req | RAM req | PVC |
| ---- | ------: | ------: | --: |
| Longhorn (1 node) | ~400m | ~512Mi | — (disk thật ≥50Gi/node) |
| MinIO | 250m | 512Mi | 50Gi |
| Jenkins (controller) | 500m | 1Gi | 10Gi |
| SonarQube + bundled PG | 750m | 2.5Gi | 13Gi |
| Harbor (all, internal DB+Redis) | ~1000m | ~2Gi | 8Gi |
| Argo CD (all) | ~900m | ~1.4Gi | — |
| **Tổng** | **~3.8 vCPU** | **~8 GiB** | **~81 GiB** |

**Cluster tối thiểu:**

- 1 node all-in-one: **8 vCPU / 16 GiB RAM / 150 GiB disk**
- 3 node (Longhorn replica 2-3): mỗi node **4 vCPU / 8 GiB / 80 GiB**

### Layer 2 — OF1 Stack

| Component | CPU req | RAM req | PVC |
| --------- | ------: | ------: | --: |
| PostgreSQL | 250m | 512Mi | 20Gi |
| Memcached | 100m | 128Mi | — |
| OpenProject web | 500m | 1Gi | data 30Gi + attachments 50Gi |
| OpenProject worker (×2) | 250m | 512Mi | — |
| n8n | 200m | 256Mi | 5Gi |
| Grafana | 100m | 128Mi | 2Gi |
| **Tổng** | **~1.7 vCPU** | **~3 GiB** | **~107 GiB** |

---

## 3. Cấu trúc repo

```text
of1/                                      ← root repo (1 git repo duy nhất)
├── DEPLOYMENT-GUIDE.md                   ← file này
│
├── platform-tool/
│   ├── bootstrap/
│   │   ├── argocd-values.yaml            # Helm values cho Argo CD
│   │   ├── create-secrets.sh             # [SCRIPT] Tạo secrets platform
│   │   ├── bootstrap.sh                  # [SCRIPT] Cài Argo CD
│   │   ├── apply-apps.sh                 # [SCRIPT] Apply App-of-Apps
│   │   └── metallb-optional.sh           # [SCRIPT][On-prem] Cài MetalLB
│   ├── apps/
│   │   ├── app-of-apps.yaml              # Root App — trỏ vào thư mục apps/
│   │   ├── ingress-nginx.yaml            # sync-wave: -1
│   │   ├── longhorn.yaml                 # sync-wave:  0
│   │   ├── minio.yaml                    # sync-wave:  0
│   │   ├── harbor.yaml                   # sync-wave:  1
│   │   ├── sonarqube.yaml                # sync-wave:  1
│   │   ├── jenkins.yaml                  # sync-wave:  2
│   │   └── backup.yaml                   # sync-wave:  3
│   └── helm-values/
│       ├── ingress-nginx/values.yaml
│       ├── longhorn/values.yaml
│       ├── minio/values.yaml
│       ├── harbor/values.yaml
│       ├── sonarqube/values.yaml
│       ├── jenkins/values.yaml
│       ├── backup/templates/
│       │   ├── longhorn-recurring-jobs.yaml
│       │   ├── pg-dump-cronjobs.yaml
│       │   └── pvc-backup-labels.yaml
│       └── metallb/                      # [On-prem only]
│           ├── values.yaml
│           └── templates/ip-pool.yaml
│
└── open-project/
    ├── argocd/
    │   ├── projects/of1-project.yaml     # ArgoCD Project — RBAC
    │   └── apps/
    │       ├── app-of-apps.yaml          # Root App OF1
    │       ├── postgresql.yaml
    │       ├── memcached.yaml
    │       ├── openproject.yaml
    │       ├── n8n.yaml
    │       └── grafana.yaml
    ├── manifests/
    │   ├── postgresql/
    │   ├── memcached/
    │   ├── openproject/
    │   ├── n8n/
    │   └── grafana/
    └── scripts/
        ├── 01-bootstrap-secrets.sh       # [SCRIPT] Tạo secrets OF1
        ├── 03-post-deploy-verify.sh      # [SCRIPT] Verify health
        └── 04-grant-grafana-ro.sh        # [SCRIPT] Grant DB permissions
```

---

## 4. Chuẩn bị trước khi triển khai

### 4.1 Kiểm tra cluster

```bash
# Kiểm tra kubectl kết nối được cluster
kubectl cluster-info

# Kiểm tra nodes
kubectl get nodes -o wide

# Kiểm tra helm
helm version
```

### 4.2 Cài dependencies trên MỌI node

```bash
# Longhorn yêu cầu open-iscsi và nfs-common
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# SonarQube yêu cầu vm.max_map_count (Elasticsearch)
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf
```

### 4.3 Điền domain thật vào config

Thay `example.local` bằng domain thật trong các file sau:

```bash
# Argo CD
# platform-tool/bootstrap/argocd-values.yaml
#   global.domain: argocd.bee.vn
#   server.ingress.hostname: argocd.bee.vn

# Helm values của từng tool
# platform-tool/helm-values/ingress-nginx/values.yaml
# platform-tool/helm-values/harbor/values.yaml  → expose.ingress.hosts.core
# platform-tool/helm-values/sonarqube/values.yaml → ingress.hosts
# platform-tool/helm-values/jenkins/values.yaml  → ingress.hostName
```

### 4.4 Điền Git repo URL

```bash
# Thay YOUR_GIT_REPO_URL bằng URL repo thật, ví dụ:
REPO="https://github.com/bee-corp/of1.git"
BRANCH="main"

# platform-tool
sed -i "s|YOUR_GIT_REPO_URL|$REPO|g; s|YOUR_GIT_BRANCH|$BRANCH|g" \
  platform-tool/bootstrap/bootstrap.sh \
  platform-tool/bootstrap/apply-apps.sh \
  platform-tool/apps/app-of-apps.yaml \
  platform-tool/apps/ingress-nginx.yaml \
  platform-tool/apps/longhorn.yaml \
  platform-tool/apps/minio.yaml \
  platform-tool/apps/harbor.yaml \
  platform-tool/apps/sonarqube.yaml \
  platform-tool/apps/jenkins.yaml \
  platform-tool/apps/backup.yaml

# open-project
sed -i "s|YOUR_GIT_REPO_URL|$REPO|g; s|YOUR_ORG/open-project|bee-corp/of1|g" \
  open-project/argocd/apps/app-of-apps.yaml \
  open-project/argocd/apps/postgresql.yaml \
  open-project/argocd/apps/memcached.yaml \
  open-project/argocd/apps/openproject.yaml \
  open-project/argocd/apps/n8n.yaml \
  open-project/argocd/apps/grafana.yaml

git add -A && git commit -m "chore: set repo url and domain" && git push
```

### 4.5 Tạo bucket CMC S3 (chạy trên CMC Cloud Portal)

```text
1. Đăng nhập CMC Cloud Portal
2. Tạo bucket tên: platform-backup
3. Bật Versioning
4. Lấy Access Key ID + Secret Access Key từ mục IAM / Access Keys
5. Ghi lại endpoint: https://s3.hn-1.cloud.cmctelecom.vn
```

---

## 5. Triển khai Platform Tool

### 5.1 [On-prem only] Cài MetalLB

> **Cloud (CMC Cloud, AWS, GCP): bỏ qua bước này.** Cloud provider tự cấp External IP.

Mở `platform-tool/helm-values/metallb/templates/ip-pool.yaml` và điền dải IP:

```bash
# Xem IP node để xác định subnet
kubectl get nodes -o wide
# Ví dụ node có IP 192.168.1.10 → đặt pool ngoài DHCP range, cùng subnet:
#   addresses: ["192.168.1.210-192.168.1.220"]
```

Sau đó chạy script cài MetalLB:

```bash
cd platform-tool/bootstrap
chmod +x metallb-optional.sh
./metallb-optional.sh
```

Verify MetalLB đã chạy:

```bash
kubectl get pods -n metallb-system
```

### 5.2 Tạo Secrets platform (KHÔNG commit vào Git)

```bash
cd platform-tool/bootstrap
chmod +x create-secrets.sh
./create-secrets.sh
```

Script hỏi lần lượt và tạo các secrets sau:

| Secret | Namespace | Nội dung |
| ------ | --------- | -------- |
| `minio-credentials` | minio | rootUser, rootPassword |
| `harbor-admin` | harbor | HARBOR_ADMIN_PASSWORD |
| `harbor-database-password` | harbor | POSTGRES_PASSWORD |
| `harbor-secret-key` | harbor | secretKey (16 ký tự) |
| `minio-harbor-creds` | harbor | accessKey, secretKey |
| `sonarqube-db-password` | sonarqube | password, postgres-password |
| `jenkins-admin` | jenkins | jenkins-admin-user, jenkins-admin-password |
| `longhorn-backup-secret` | longhorn-system | AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS |
| `cmc-s3-credentials` | harbor, sonarqube | CMC S3 key cho pg_dump CronJob |

Verify secrets đã tạo:

```bash
kubectl get secrets -A | grep -E "minio|harbor|sonar|jenkins|longhorn-backup|cmc-s3"
```

### 5.3 Cài Argo CD

```bash
cd platform-tool/bootstrap
chmod +x bootstrap.sh
./bootstrap.sh
```

Script thực hiện:

1. Add Helm repos (argo, metallb, ingress-nginx, longhorn, minio, harbor, sonarqube, jenkins)
2. Tạo namespace `argocd`
3. `helm upgrade --install argocd argo/argo-cd -f argocd-values.yaml --wait`
4. In URL + initial password

Verify Argo CD đang chạy:

```bash
kubectl get pods -n argocd
kubectl get ingress -n argocd
```

Lấy initial password nếu cần:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### 5.4 Apply App-of-Apps — Platform Tool

```bash
cd platform-tool/bootstrap
chmod +x apply-apps.sh

# Apply chỉ platform-tool trước
./apply-apps.sh ../apps/app-of-apps.yaml
```

### 5.5 Theo dõi sync platform-tool

```bash
# Xem tất cả Application và trạng thái
kubectl get applications -n argocd

# Theo dõi real-time
kubectl get applications -n argocd -w

# Xem chi tiết 1 app đang lỗi
kubectl describe application longhorn -n argocd

# Xem sync history
argocd app history platform-apps
```

Thứ tự Healthy kỳ vọng:

```text
wave -1: ingress-nginx  → Healthy, EXTERNAL-IP assigned  (~2 phút)
wave  0: longhorn       → Healthy                        (~3-5 phút)
         minio          → Healthy (sau khi Longhorn cấp PVC)
wave  1: harbor         → Healthy                        (~5-8 phút)
         sonarqube      → Healthy (ES khởi động lâu)     (~5-8 phút)
wave  2: jenkins        → Healthy                        (~3-5 phút)
wave  3: backup         → Synced  (CronJob + RecurringJob)
```

### 5.6 Tạo bucket MinIO cho OpenProject

Sau khi MinIO Healthy, tạo bucket cho OpenProject attachments:

```bash
# Port-forward để dùng mc CLI
kubectl port-forward svc/minio -n minio 9000:9000 &

# Lấy credentials từ secret
MINIO_USER=$(kubectl get secret minio-credentials -n minio \
  -o jsonpath='{.data.rootUser}' | base64 -d)
MINIO_PASS=$(kubectl get secret minio-credentials -n minio \
  -o jsonpath='{.data.rootPassword}' | base64 -d)

# Tạo alias và bucket
mc alias set local http://localhost:9000 "$MINIO_USER" "$MINIO_PASS"
mc mb local/openproject-attachments
mc mb local/harbor-registry          # nếu chưa có
mc anonymous set none local/openproject-attachments

# Verify
mc ls local/
```

---

## 6. Triển khai OF1 Stack

> **Yêu cầu:** Argo CD và Longhorn (wave 0) phải ở trạng thái Healthy trước.

### 6.1 Tạo Secrets OF1 (KHÔNG commit vào Git)

Trước khi chạy script, set các biến môi trường bắt buộc:

```bash
export TEAMS_WEBHOOK_URL="https://beevn.webhook.office.com/webhookb2/..."  # bắt buộc
export MINIO_ACCESS_KEY="<access-key-lấy-từ-MinIO>"
export MINIO_SECRET_KEY="<secret-key-lấy-từ-MinIO>"

# Các biến dưới tự sinh ngẫu nhiên nếu không set
# export PG_ROOT_PASSWORD="..."
# export GRAFANA_ADMIN_PASSWORD="..."
```

Chạy script:

```bash
cd open-project
chmod +x scripts/01-bootstrap-secrets.sh
bash scripts/01-bootstrap-secrets.sh
```

Script in ra tất cả giá trị đã sinh — **lưu ngay vào password manager** trước khi đóng terminal.

Verify secrets đã tạo:

```bash
kubectl get secrets -n openproject
kubectl get secrets -n n8n
kubectl get secrets -n monitoring
```

### 6.2 Apply App-of-Apps — OF1 Stack

```bash
cd platform-tool/bootstrap

# Apply OF1 stack vào Argo CD
./apply-apps.sh ../../open-project/argocd/apps/app-of-apps.yaml
```

Verify Application đã được tạo:

```bash
kubectl get applications -n argocd | grep of1
```

### 6.3 Theo dõi sync OF1 stack

```bash
# Theo dõi real-time
kubectl get applications -n argocd -w

# Xem pod đang khởi động
kubectl get pods -n openproject -w
kubectl get pods -n n8n -w
kubectl get pods -n monitoring -w

# Xem log initContainer migrate của OpenProject
kubectl logs -n openproject deploy/openproject-web -c db-migrate -f
```

Thứ tự sync: `of1-postgresql` → `of1-memcached` → `of1-openproject` → `of1-n8n` → `of1-grafana`

### 6.4 Grant quyền đọc DB cho Grafana

Chạy sau khi OpenProject web pod Healthy (initContainer `db-migrate` đã xong):

```bash
bash open-project/scripts/04-grant-grafana-ro.sh
```

Script thực hiện 2 việc:

1. `GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro`
2. Verify bằng cách query `SELECT COUNT(*) FROM work_packages` với user `grafana_ro`

### 6.5 Verify toàn stack

```bash
bash open-project/scripts/03-post-deploy-verify.sh
```

Script kiểm tra: pods running · services · HTTP health endpoints · DB connectivity · secrets · ArgoCD sync status.

Hoặc kiểm tra thủ công:

```bash
# Pods
kubectl get pods -n openproject
kubectl get pods -n n8n
kubectl get pods -n monitoring

# Ingress
kubectl get ingress -n openproject
kubectl get ingress -n n8n
kubectl get ingress -n monitoring

# ArgoCD sync status của tất cả OF1 apps
kubectl get applications -n argocd | grep of1

# HTTP health
curl -sf https://openproject.bee.vn/health_check && echo "OK"
curl -sf https://n8n.bee.vn/healthz && echo "OK"
curl -sf https://grafana.bee.vn/api/health && echo "OK"
```

---

## 7. Vận hành hàng ngày

### 7.1 Thay đổi config — Platform Tool

Tất cả thay đổi đều theo luồng: **sửa file → commit → push → Argo CD tự sync**.

```bash
# Ví dụ: tăng RAM limit SonarQube
# Sửa platform-tool/helm-values/sonarqube/values.yaml
git add platform-tool/helm-values/sonarqube/values.yaml
git commit -m "feat: increase sonarqube RAM limit to 6Gi"
git push

# Theo dõi Argo CD sync
kubectl get application sonarqube -n argocd -w
```

| Muốn làm gì | File cần sửa |
| --- | --- |
| Tăng RAM/CPU SonarQube | `helm-values/sonarqube/values.yaml` |
| Nâng version Harbor | `apps/harbor.yaml` → trường `targetRevision` |
| Thêm Jenkins plugin | `helm-values/jenkins/values.yaml` → `installPlugins` |
| Tăng Longhorn replica | `helm-values/longhorn/values.yaml` → `defaultReplicaCount` |
| Rollback về config cũ | `git revert <commit>` → push |

> `kubectl edit` hay `helm upgrade` tay sẽ bị Argo CD revert trong lần sync tiếp theo (`selfHeal: true`).

### 7.2 Thay đổi config — OF1 Stack

```bash
# Ví dụ: thay image tag OpenProject
# Sửa open-project/manifests/openproject/deployment-web.yaml
#       open-project/manifests/openproject/deployment-worker.yaml
git add open-project/manifests/openproject/
git commit -m "chore: upgrade openproject to 14.2.0"
git push

# Argo CD sync → initContainer db-migrate chạy tự động trước khi web pod lên
kubectl logs -n openproject deploy/openproject-web -c db-migrate -f

# Sau upgrade phải grant lại quyền cho grafana_ro (bảng mới có thể xuất hiện)
bash open-project/scripts/04-grant-grafana-ro.sh
```

### 7.3 Xoay secret (password rotation)

```bash
# Ví dụ: đổi Grafana admin password
kubectl create secret generic grafana-secrets \
  --namespace monitoring \
  --from-literal=admin-password='NEW_STRONG_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment grafana -n monitoring
kubectl rollout status deployment grafana -n monitoring
```

### 7.4 Thêm Grafana dashboard

```bash
# 1. Export JSON từ Grafana UI: Share → Export → Save to file
# 2. Thêm vào ConfigMap trong file:
#    open-project/manifests/grafana/configmaps.yaml
# 3. Commit và push

git add open-project/manifests/grafana/configmaps.yaml
git commit -m "feat: add cycle-time dashboard"
git push

# Grafana tự reload sau 30 giây — không cần restart
```

### 7.5 Thêm App-of-Apps mới (stack mới trong tương lai)

```bash
# Thêm đường dẫn vào APPS_LIST trong apply-apps.sh rồi chạy lại
cd platform-tool/bootstrap
./apply-apps.sh ../../new-stack/argocd/apps/app-of-apps.yaml
```

---

## 8. Troubleshooting

### Argo CD

```bash
# Xem tất cả apps
kubectl get applications -n argocd

# App bị OutOfSync hoặc Degraded
kubectl get application <tên> -n argocd -o yaml | grep -A 10 "conditions:"

# Xem diff giữa Git và cluster
argocd app diff <tên>

# Force sync
argocd app sync <tên> --force

# Xem events
kubectl describe application <tên> -n argocd
```

### Platform Tool

```bash
# ingress-nginx không có EXTERNAL-IP
kubectl get svc -n ingress-nginx
# On-prem: kiểm tra MetalLB
kubectl describe ipaddresspool platform-pool -n metallb-system 2>/dev/null || \
  echo "MetalLB chưa cài — chạy bootstrap/metallb-optional.sh"

# SonarQube không start — kiểm tra vm.max_map_count
kubectl logs -n sonarqube -l app=sonarqube | grep "max virtual memory"
# Fix trên node:
sudo sysctl -w vm.max_map_count=262144

# Harbor push lỗi — kiểm tra MinIO kết nối
kubectl logs -n harbor deployment/harbor-registry | grep -i "error\|s3"
# Kiểm tra MinIO bucket tồn tại
mc ls local/harbor-registry

# Longhorn backup lỗi — kiểm tra endpoint CMC S3
kubectl get secret longhorn-backup-secret -n longhorn-system \
  -o jsonpath='{.data.AWS_ENDPOINTS}' | base64 -d && echo

# Xem Longhorn backup status
kubectl get recurringjob -n longhorn-system
```

### OF1 Stack

```bash
# OpenProject web pod không lên (CrashLoopBackOff)
kubectl logs -n openproject deploy/openproject-web -c db-migrate --tail=50
kubectl logs -n openproject deploy/openproject-web -c web --tail=50

# OpenProject worker không chạy
kubectl logs -n openproject deploy/openproject-worker --tail=50

# PostgreSQL không healthy
kubectl logs -n openproject statefulset/postgresql --tail=50
kubectl exec -n openproject statefulset/postgresql -- pg_isready -U postgres

# Grafana không query được PostgreSQL
# Chạy lại grant script
bash open-project/scripts/04-grant-grafana-ro.sh
# Kiểm tra grafana_ro có trong DB chưa
kubectl exec -n openproject statefulset/postgresql -- \
  psql -U postgres -c "\du grafana_ro"

# n8n webhook không nhận event từ OpenProject
# Lấy webhook secret hiện tại
kubectl get secret n8n-secrets -n n8n \
  -o jsonpath='{.data.openproject-webhook-secret}' | base64 -d && echo
# Vào OpenProject > Administration > Webhooks và xác nhận secret khớp

# Kiểm tra certificate TLS
kubectl get certificate -n openproject
kubectl describe certificate openproject-tls -n openproject
```

---

## 9. URLs & Domains

### Platform Tool — URLs

| Tool | Namespace | URL |
| ---- | --------- | --- |
| Argo CD | `argocd` | `https://argocd.bee.vn` |
| Harbor | `harbor` | `https://harbor.bee.vn` |
| SonarQube | `sonarqube` | `http://sonarqube.bee.vn` |
| Jenkins | `jenkins` | `http://jenkins.bee.vn` |
| MinIO console | `minio` | port-forward hoặc bật ingress |
| Longhorn UI | `longhorn-system` | port-forward hoặc bật ingress |

```bash
# Port-forward MinIO console
kubectl port-forward svc/minio-console -n minio 9001:9001
# Truy cập: http://localhost:9001

# Port-forward Longhorn UI
kubectl port-forward svc/longhorn-frontend -n longhorn-system 8080:80
# Truy cập: http://localhost:8080
```

### OF1 Stack — URLs

| Service | Namespace | URL |
| ------- | --------- | --- |
| OpenProject | `openproject` | `https://openproject.bee.vn` |
| n8n | `n8n` | `https://n8n.bee.vn` |
| Grafana | `monitoring` | `https://grafana.bee.vn` |

TLS được cấp tự động bởi cert-manager + Let's Encrypt (`letsencrypt-prod` ClusterIssuer).

---

## Tài liệu chi tiết

| Tài liệu | Mô tả |
| -------- | ----- |
| [platform-tool/INSTALL.md](platform-tool/INSTALL.md) | Hướng dẫn cài platform chi tiết |
| [platform-tool/k8s-platform-resource-requirements.md](platform-tool/k8s-platform-resource-requirements.md) | Resource table đầy đủ + production safety notes |
| [open-project/GUIDELINE.md](open-project/GUIDELINE.md) | GitOps design principles cho OF1 stack |
| [open-project/of1-openproject-deployment-guide.md](open-project/of1-openproject-deployment-guide.md) | Cấu hình OpenProject end-to-end (types, statuses, roles, metrics SQL) |
