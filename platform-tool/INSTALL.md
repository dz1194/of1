# Platform Tool — GitOps Installation Guide

> **Nguyên tắc:** Sau bước bootstrap, **Git là source of truth**.
> Mọi thay đổi config → sửa file → `git push` → Argo CD tự sync.
> Không bao giờ chạy `helm upgrade` hay `kubectl apply` tay nữa (trừ Secrets).

---

## Cấu trúc repo

```text
platform-tool/
├── bootstrap/                        # Imperative — chạy 1 lần duy nhất
│   ├── argocd-values.yaml            # Argo CD helm values
│   ├── create-secrets.sh             # Tạo K8s Secrets (KHÔNG commit vào Git)
│   ├── bootstrap.sh                  # Cài Argo CD + apply App-of-Apps
│   └── metallb-optional.sh          # [OPTIONAL] Chỉ cần cho on-prem, bỏ qua nếu cloud
│
├── apps/                             # Argo CD Application CRs — Git = source of truth
│   ├── app-of-apps.yaml              # Root App trỏ vào thư mục này
│   ├── ingress-nginx.yaml            # sync-wave: -1
│   ├── longhorn.yaml                 # sync-wave:  0  (chờ wave -1 Healthy)
│   ├── minio.yaml                    # sync-wave:  0
│   ├── harbor.yaml                   # sync-wave:  1  (chờ wave 0 Healthy)
│   ├── sonarqube.yaml                # sync-wave:  1
│   ├── jenkins.yaml                  # sync-wave:  2  (chờ wave 1 Healthy)
│   └── backup.yaml                   # sync-wave:  3  (chờ wave 2 Healthy)
│
└── helm-values/                      # Helm values cho từng tool
    ├── metallb/                      # [OPTIONAL] Chỉ dùng cho on-prem
    │   ├── values.yaml
    │   └── templates/ip-pool.yaml    # Điền dải IP thật trước khi chạy metallb-optional.sh
    ├── ingress-nginx/values.yaml
    ├── longhorn/values.yaml
    ├── minio/values.yaml
    ├── harbor/values.yaml
    ├── sonarqube/values.yaml
    ├── jenkins/values.yaml
    └── backup/templates/             # Raw K8s manifests
        ├── longhorn-recurring-jobs.yaml
        ├── pg-dump-cronjobs.yaml
        └── pvc-backup-labels.yaml
```

---

## Luồng sync-wave

```text
[on-prem only] metallb-optional.sh   ← manual, chạy trước bootstrap nếu cần
    │
bootstrap.sh  (imperative, 1 lần)
    │
    ▼  install Argo CD + apply app-of-apps.yaml
┌──────────────────────────────────────────────────────┐
│  wave -1  ingress-nginx                              │
│           on-prem: nhận IP từ MetalLB                │
│           cloud:   nhận IP từ cloud provider         │
│                     ↓ Healthy                        │
│  wave  0  Longhorn ─────────────── MinIO             │
│           (default StorageClass)   (PVC 50Gi, S3)    │
│                     ↓ Healthy                        │
│  wave  1  Harbor ──────── SonarQube                  │
│           (MinIO S3)      (bundled PG)               │
│                     ↓ Healthy                        │
│  wave  2  Jenkins                                    │
│           (JENKINS_HOME PVC 10Gi)                    │
│                     ↓ Healthy                        │
│  wave  3  Backup                                     │
│           (RecurringJobs + pg_dump CronJobs)         │
└──────────────────────────────────────────────────────┘
```

Argo CD chỉ bắt đầu sync wave N+1 sau khi **tất cả** resource ở wave N đạt trạng thái **Healthy**.

---

## Trước khi bắt đầu — Checklist

- [ ] Node đủ spec: **8 vCPU / 16 GiB RAM / 150 GiB disk** (1-node) hoặc **3 × (4/8/80)**
- [ ] Kubernetes cluster chạy (kubeadm / k3s / rke2)
- [ ] Repo này đã push lên Git và accessible từ cluster
- [ ] Bucket `platform-backup` đã tạo trên CMC Cloud, bật Versioning
- [ ] **\[On-prem only\]** Điền dải IP vào `helm-values/metallb/templates/ip-pool.yaml`
- [ ] Đã thay tất cả `example.local` bằng domain thật trong `helm-values/*/values.yaml`
- [ ] Đã thay `YOUR_GIT_REPO_URL` trong `bootstrap/bootstrap.sh` và tất cả file `apps/*.yaml`

---

## Bước 1 — Chuẩn bị node (chạy trên MỌI node)

```bash
# Cài open-iscsi (Longhorn) + set vm.max_map_count (SonarQube)
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf
```

---

## Bước 2 — \[On-prem only\] Cài MetalLB

> **Trên cloud: bỏ qua bước này.** Cloud provider tự cấp External IP cho LoadBalancer Service.

Mở `helm-values/metallb/templates/ip-pool.yaml`, điền dải IP phù hợp với mạng:

```bash
# Xem IP node để xác định subnet
kubectl get nodes -o wide
# Ví dụ node 192.168.1.10 → đặt pool ngoài DHCP range, cùng subnet:
#   addresses: ["192.168.1.210-192.168.1.220"]
```

Sau đó chạy:

```bash
cd bootstrap
chmod +x metallb-optional.sh
./metallb-optional.sh
```

---

## Bước 3 — Điền Git repo URL

```bash
REPO="https://github.com/YOUR_ORG/platform-tool.git"

sed -i "s|YOUR_GIT_REPO_URL|$REPO|g" \
  bootstrap/bootstrap.sh \
  apps/ingress-nginx.yaml \
  apps/longhorn.yaml \
  apps/minio.yaml \
  apps/harbor.yaml \
  apps/sonarqube.yaml \
  apps/jenkins.yaml \
  apps/backup.yaml

git add -A && git commit -m "chore: set git repo url" && git push
```

---

## Bước 4 — Tạo Secrets (KHÔNG commit vào Git)

```bash
cd bootstrap
chmod +x create-secrets.sh
./create-secrets.sh
```

Script hỏi lần lượt:

- MinIO root password
- Harbor admin password, DB password, secretKey (16 ký tự)
- SonarQube DB password
- Jenkins admin password
- CMC S3 Access Key ID + Secret Access Key

> **Tạo lại 1 secret cụ thể:**
>
> ```bash
> kubectl create secret generic <tên> -n <namespace> \
>   --from-literal=key=value \
>   --dry-run=client -o yaml | kubectl apply -f -
> ```

---

## Bước 5 — Bootstrap (chạy 1 lần duy nhất)

```bash
cd bootstrap
chmod +x bootstrap.sh
./bootstrap.sh
```

Script thực hiện:

1. Cài Argo CD qua Helm
2. Apply `apps/app-of-apps.yaml` — trigger để Argo CD đọc toàn bộ thư mục `apps/`
3. In Argo CD URL + initial password

---

## Bước 6 — Theo dõi quá trình sync

```bash
# Xem toàn bộ Application và trạng thái
kubectl get applications -n argocd

# Theo dõi real-time
kubectl get applications -n argocd -w

# Xem chi tiết 1 app đang lỗi
kubectl describe application longhorn -n argocd
```

Thứ tự Healthy kỳ vọng:

```text
[on-prem] metallb-optional.sh → manual, chạy trước bootstrap
wave -1: ingress-nginx → Healthy, EXTERNAL-IP assigned (~ 2 phút)
wave  0: longhorn      → Healthy (~ 3-5 phút)
         minio         → Healthy (sau khi Longhorn cấp PVC)
wave  1: harbor        → Healthy (~ 5-8 phút)
         sonarqube     → Healthy (~ 5-8 phút, ES khởi động lâu)
wave  2: jenkins       → Healthy (~ 3-5 phút)
wave  3: backup        → Synced  (CronJob + RecurringJob apply)
```

---

## Vận hành hàng ngày — Thay đổi config qua Git

| Muốn làm gì | Thao tác |
| --- | --- |
| Tăng RAM limit SonarQube | Sửa `helm-values/sonarqube/values.yaml` → commit → push |
| Nâng version Harbor | Sửa `targetRevision` trong `apps/harbor.yaml` → commit → push |
| Thêm Jenkins plugin | Sửa `installPlugins` trong `helm-values/jenkins/values.yaml` → commit → push |
| \[On-prem\] Thêm IP vào MetalLB pool | Sửa `helm-values/metallb/templates/ip-pool.yaml` → chạy `metallb-optional.sh` lại |
| Tăng Longhorn replica | Sửa `defaultReplicaCount` trong `helm-values/longhorn/values.yaml` → commit → push |
| Rollback về config cũ | `git revert <commit>` → push → Argo CD tự sync về trạng thái cũ |

> **Không bao giờ** chạy `helm upgrade` hay `kubectl edit` tay — Argo CD sẽ revert về Git trong lần sync tiếp theo (selfHeal: true).

---

## Troubleshooting

```bash
# App bị OutOfSync hoặc Degraded
kubectl get application <tên> -n argocd -o yaml | grep -A 10 "conditions:"

# Force sync 1 app
argocd app sync <tên> --force

# ingress-nginx không có EXTERNAL-IP
kubectl get svc -n ingress-nginx
# On-prem: kiểm tra MetalLB đã cài và IP pool đúng chưa
kubectl describe ipaddresspool platform-pool -n metallb-system 2>/dev/null || \
  echo "MetalLB chưa cài — chạy bootstrap/metallb-optional.sh"
# Cloud: kiểm tra cloud LB controller còn hoạt động không

# SonarQube không start — ES lỗi vm.max_map_count
kubectl logs -n sonarqube -l app=sonarqube | grep "max virtual memory"

# Harbor push lỗi — kiểm tra MinIO kết nối
kubectl logs -n harbor deployment/harbor-registry | grep -i "error\|s3"

# Longhorn backup lỗi — kiểm tra Secret AWS_ENDPOINTS
kubectl get secret longhorn-backup-secret -n longhorn-system \
  -o jsonpath='{.data.AWS_ENDPOINTS}' | base64 -d
```

---

## Quick reference

| Tool | Namespace | URL |
| --- | --- | --- |
| Argo CD | `argocd` | `https://argocd.example.local` |
| Harbor | `harbor` | `https://harbor.example.local` |
| SonarQube | `sonarqube` | `http://sonarqube.example.local` |
| Jenkins | `jenkins` | `http://jenkins.example.local` |
| MinIO console | `minio` | ClusterIP only — bật ingress nếu cần |
| Longhorn UI | `longhorn-system` | port-forward hoặc bật ingress |
