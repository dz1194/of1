# Hướng dẫn Triển khai GitOps — OF1 Platform

**Stack:** Longhorn · MinIO · Harbor · SonarQube · Jenkins · OpenProject · n8n · Grafana  
**Pattern:** ArgoCD App-of-Apps với sync-wave theo dependency  
**Domain:** `*.bee.local` · **TLS:** cert-manager self-signed CA

---

## Mục lục

1. [Yêu cầu trước khi bắt đầu](#1-yêu-cầu-trước-khi-bắt-đầu)
2. [Chuẩn bị cluster](#2-chuẩn-bị-cluster)
3. [Đẩy repo lên Git](#3-đẩy-repo-lên-git)
4. [Tạo Secrets](#4-tạo-secrets)
5. [Bootstrap ArgoCD](#5-bootstrap-argocd)
6. [Verify từng service](#6-verify-từng-service)
7. [Cấu hình sau khi deploy](#7-cấu-hình-sau-khi-deploy)
8. [Backup ra CMC S3](#8-backup-ra-cmc-s3)
9. [DNS nội bộ](#9-dns-nội-bộ)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Yêu cầu trước khi bắt đầu

### Cluster tối thiểu
| Hạng mục | Tối thiểu (1 node) | Khuyến nghị (3 node) |
|---|---|---|
| CPU | 8 vCPU | 3 × 4 vCPU |
| RAM | 16 GiB | 3 × 8 GiB |
| Disk | 150 GiB | 3 × 80 GiB |

### Đã cài sẵn trên cluster
- [ ] ArgoCD (đã có)
- [ ] ingress-nginx
- [ ] MetalLB hoặc LoadBalancer provider

### Tools trên máy local
```bash
kubectl version --client   # >= 1.28
helm version               # >= 3.12
argocd version             # CLI (tuỳ chọn, để sync thủ công)
```

---

## 2. Chuẩn bị cluster

### 2.1. Prerequisites cho SonarQube (Elasticsearch)

Chạy trên **mọi node** trong cluster:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf
```

### 2.2. Prerequisites cho Longhorn

Chạy trên **mọi node**:

```bash
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Verify:
```bash
sudo systemctl status iscsid
```

### 2.3. Kiểm tra ingress-nginx và LoadBalancer

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx   # cần có EXTERNAL-IP cho LoadBalancer
```

---

## 3. Đẩy repo lên Git

```bash
# Tạo repo mới trên GitLab/GitHub, sau đó:
cd d:/Code/DevOps/Bee/of1

git remote set-url origin https://github.com/dz1194/of1.git
# hoặc nếu chưa có remote:
git remote add origin https://github.com/dz1194/of1.git

git push -u origin main
```

### 3.1. Kết nối ArgoCD với repo

```bash
# Nếu repo public: không cần thêm gì
# Nếu repo private:
argocd repo add https://github.com/dz1194/of1.git \
  --username YOUR_GITHUB_USERNAME \
  --password YOUR_GITHUB_TOKEN
```

---

## 4. Tạo Secrets

> **Quan trọng:** Tạo đủ Secrets trước khi apply root-app. ArgoCD sync sẽ fail nếu Secret chưa tồn tại.

### 4.1. MinIO

```bash
kubectl create namespace minio

kubectl create secret generic minio-credentials -n minio \
  --from-literal=rootUser=minioadmin \
  --from-literal=rootPassword=$(openssl rand -base64 20)
```

### 4.2. Harbor

```bash
kubectl create namespace harbor

kubectl create secret generic harbor-admin-secret -n harbor \
  --from-literal=HARBOR_ADMIN_PASSWORD=$(openssl rand -base64 20)

kubectl create secret generic harbor-secret-key -n harbor \
  --from-literal=secretKey=$(openssl rand -hex 8)

kubectl create secret generic harbor-db-secret -n harbor \
  --from-literal=POSTGRES_PASSWORD=$(openssl rand -base64 20)

# Credentials MinIO cho Harbor registry — phải khớp với minio-credentials ở trên
kubectl create secret generic harbor-s3-secret -n harbor \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=minioadmin \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY=SAME_AS_MINIO_PASSWORD
```

### 4.3. SonarQube

SonarQube dùng bundled PostgreSQL — không cần tạo Secret thêm (chart tự sinh).  
Nếu muốn custom password:
```bash
kubectl create namespace sonarqube
kubectl create secret generic sonarqube-postgresql -n sonarqube \
  --from-literal=postgresql-password=$(openssl rand -base64 20) \
  --from-literal=postgresql-postgres-password=$(openssl rand -base64 20)
```

### 4.4. Jenkins

```bash
kubectl create namespace jenkins

kubectl create secret generic jenkins-admin-secret -n jenkins \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password=$(openssl rand -base64 20)
```

### 4.5. OpenProject

```bash
kubectl create namespace openproject

# DB password (phải nhất quán — dùng cùng giá trị cho cả 2 key)
OP_DB_PASS=$(openssl rand -base64 20)

kubectl create secret generic openproject-postgresql -n openproject \
  --from-literal=postgres-password=$OP_DB_PASS \
  --from-literal=password=$OP_DB_PASS

kubectl create secret generic openproject-env-secret -n openproject \
  --from-literal=DATABASE_URL="postgres://postgres:${OP_DB_PASS}@openproject-postgresql/openproject?pool=20" \
  --from-literal=OPENPROJECT_SECRET__KEY__BASE=$(openssl rand -hex 64)
```

### 4.6. n8n

```bash
kubectl create namespace n8n

kubectl create secret generic n8n-secret -n n8n \
  --from-literal=N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
```

### 4.7. Grafana

```bash
kubectl create namespace grafana

kubectl create secret generic grafana-admin-secret -n grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=$(openssl rand -base64 20)

# Read-only password vào OpenProject PostgreSQL (tạo user trước — xem §7.1)
kubectl create secret generic grafana-datasource-secret -n grafana \
  --from-literal=password=GRAFANA_RO_PASSWORD
```

---

## 5. Bootstrap ArgoCD

### 5.1. Apply root app (một lần duy nhất)

```bash
kubectl apply -f gitops/apps/root-app.yaml
```

ArgoCD sẽ phát hiện thư mục `applications/` và tạo tất cả Application objects.  
Sync diễn ra theo thứ tự sync-wave tự động:

| Wave | Tool | Namespace |
|------|------|-----------|
| 0 | cert-manager, Longhorn | cert-manager, longhorn-system |
| 1 | cert-manager-issuers (CA) | cert-manager |
| 2 | MinIO | minio |
| 3 | Harbor, SonarQube | harbor, sonarqube |
| 4 | Jenkins, OpenProject | jenkins, openproject |
| 5 | n8n, Grafana | n8n, grafana |

### 5.2. Theo dõi tiến trình

```bash
# Xem tất cả Application
kubectl get applications -n argocd

# Xem log sync của root app
argocd app get root --refresh

# Theo dõi một app cụ thể
argocd app logs longhorn -n argocd
```

### 5.3. Sync thủ công nếu cần

```bash
argocd app sync cert-manager
argocd app sync longhorn
# v.v.
```

---

## 6. Verify từng service

### Longhorn
```bash
kubectl get pods -n longhorn-system
# Truy cập UI: https://longhorn.bee.local
# Kiểm tra StorageClass là default:
kubectl get sc
```

### MinIO
```bash
kubectl get pods -n minio
# Truy cập console: https://minio-console.bee.local
# Login bằng credentials trong secret minio-credentials
# Kiểm tra bucket harbor-registry đã tồn tại
```

### Harbor
```bash
kubectl get pods -n harbor
# Truy cập: https://harbor.bee.local
# Login: admin / (password từ harbor-admin-secret)
# Test push image:
docker login harbor.bee.local
docker pull hello-world
docker tag hello-world harbor.bee.local/library/hello-world:test
docker push harbor.bee.local/library/hello-world:test
```

> **Lưu ý:** Nếu dùng self-signed CA, cần thêm CA cert vào trust store của Docker daemon trên mọi node.  
> CA cert lấy từ: `kubectl get secret bee-local-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d`

### SonarQube
```bash
kubectl get pods -n sonarqube
# Truy cập: https://sonar.bee.local
# Login mặc định: admin / admin (đổi ngay sau lần đầu)
```

### Jenkins
```bash
kubectl get pods -n jenkins
# Truy cập: https://jenkins.bee.local
# Login: admin / (password từ jenkins-admin-secret)
# Chạy 1 pipeline test để verify agent pod tự spin up
```

### OpenProject
```bash
kubectl get pods -n openproject
# Truy cập: https://openproject.bee.local
# Login mặc định: admin / admin (đổi ngay)
# Tạo project "00 - Intake" để test
```

### n8n
```bash
kubectl get pods -n n8n
# Truy cập: https://n8n.bee.local
# Tạo workflow test gọi OpenProject API
```

### Grafana
```bash
kubectl get pods -n grafana
# Truy cập: https://grafana.bee.local
# Kiểm tra datasource "OpenProject PostgreSQL" → Test connection
```

---

## 7. Cấu hình sau khi deploy

### 7.1. Tạo read-only user Grafana trên PostgreSQL của OpenProject

```bash
# Exec vào pod PostgreSQL của OpenProject
kubectl exec -it -n openproject \
  $(kubectl get pod -n openproject -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres openproject
```

Chạy trong psql:
```sql
CREATE ROLE grafana_ro LOGIN PASSWORD 'GRAFANA_RO_PASSWORD';
GRANT CONNECT ON DATABASE openproject TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
\q
```

Sau đó cập nhật Secret `grafana-datasource-secret` với đúng password, rồi restart Grafana:
```bash
kubectl rollout restart deployment/grafana -n grafana
```

### 7.2. Cấu hình OpenProject webhook cho n8n

Trong OpenProject: **Administration → API and webhooks → Add webhook**
- URL: `https://n8n.bee.local/webhook/openproject`
- Events: `Work package created`, `Work package updated`

### 7.3. Cấu hình SMTP cho OpenProject

Chỉnh lại trong [helm-values/openproject/values.yaml](helm-values/openproject/values.yaml):
```yaml
environment:
  OPENPROJECT_SMTP__ADDRESS: smtp.bee.local   # địa chỉ SMTP thật
  OPENPROJECT_SMTP__PORT: "587"
  OPENPROJECT_SMTP__DOMAIN: bee.local
  OPENPROJECT_SMTP__USER__NAME: "noreply@bee.local"
  OPENPROJECT_SMTP__PASSWORD: "SMTP_PASSWORD"  # nên dùng Secret thay vì hardcode
```

### 7.4. Thêm CA cert vào Docker daemon (Harbor)

Trên mọi node cần push/pull từ Harbor:
```bash
# Lấy CA cert
kubectl get secret bee-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > bee-local-ca.crt

# Cài vào Docker
sudo mkdir -p /etc/docker/certs.d/harbor.bee.local
sudo cp bee-local-ca.crt /etc/docker/certs.d/harbor.bee.local/ca.crt
sudo systemctl restart docker
```

---

## 8. Backup ra CMC S3

### 8.1. Tạo bucket và lấy credentials trên CMC Cloud Portal
- Bucket: `of1-platform-backup`
- Bật Versioning
- Endpoint: `https://s3.hn-1.cloud.cmctelecom.vn` (thay region nếu khác)

### 8.2. Cấu hình Longhorn backup target

```bash
kubectl create secret generic longhorn-backup-secret -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID=CMC_ACCESS_KEY \
  --from-literal=AWS_SECRET_ACCESS_KEY=CMC_SECRET_KEY \
  --from-literal=AWS_ENDPOINTS=https://s3.hn-1.cloud.cmctelecom.vn
```

Trong Longhorn UI: **Settings → Backup → Backup Target**
```
s3://of1-platform-backup@hn-1/longhorn
```
**Backup Target Credential Secret:** `longhorn-backup-secret`

### 8.3. Tạo RecurringJob backup cho PVC quan trọng

```bash
# Backup hằng ngày lúc 2:00 AM, giữ 7 bản
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  groups:
    - default
  retain: 7
  concurrency: 1
EOF
```

### 8.4. CronJob dump PostgreSQL lên CMC S3

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: openproject
spec:
  schedule: "30 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: postgres:16-alpine
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: openproject-postgresql
                      key: postgres-password
                - name: AWS_ACCESS_KEY_ID
                  value: CMC_ACCESS_KEY
                - name: AWS_SECRET_ACCESS_KEY
                  value: CMC_SECRET_KEY
              command:
                - /bin/sh
                - -c
                - |
                  TS=\$(date +%Y%m%d-%H%M)
                  pg_dump -h openproject-postgresql -U postgres openproject | gzip > /tmp/op-\$TS.sql.gz
                  aws s3 cp /tmp/op-\$TS.sql.gz \
                    s3://of1-platform-backup/postgres/op-\$TS.sql.gz \
                    --endpoint-url https://s3.hn-1.cloud.cmctelecom.vn
EOF
```

---

## 9. DNS nội bộ

Thêm A records trên DNS server nội bộ (hoặc `/etc/hosts` khi test) trỏ về EXTERNAL-IP của ingress-nginx:

```bash
# Lấy IP của ingress
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Records cần thêm (thay `<INGRESS_IP>`):
```
<INGRESS_IP>  longhorn.bee.local
<INGRESS_IP>  minio.bee.local
<INGRESS_IP>  minio-console.bee.local
<INGRESS_IP>  harbor.bee.local
<INGRESS_IP>  sonar.bee.local
<INGRESS_IP>  jenkins.bee.local
<INGRESS_IP>  openproject.bee.local
<INGRESS_IP>  n8n.bee.local
<INGRESS_IP>  grafana.bee.local
```

---

## 10. Troubleshooting

### Pod không start — ImagePullBackOff từ Harbor
CA cert chưa được trust. Xem §7.4.

### SonarQube crash — Elasticsearch OOMKilled
Tăng RAM limit trong [helm-values/sonarqube/values.yaml](helm-values/sonarqube/values.yaml):
```yaml
resources:
  limits:
    memory: 6Gi
```
Hoặc kiểm tra `vm.max_map_count` đã được set chưa (§2.1).

### Harbor không kết nối được MinIO
```bash
# Kiểm tra registry pod log
kubectl logs -n harbor -l component=registry

# Test kết nối từ trong cluster
kubectl run -it --rm debug --image=alpine -n harbor -- \
  wget -qO- http://minio.minio.svc.cluster.local:9000/minio/health/live
```

### cert-manager không issue được cert
```bash
kubectl describe certificate -n <namespace> <cert-name>
kubectl describe certificaterequest -n <namespace>
kubectl logs -n cert-manager -l app=cert-manager
```

### ArgoCD sync bị stuck ở wave
```bash
# Xem chi tiết lỗi của Application đang block
argocd app get <app-name>
kubectl describe application <app-name> -n argocd
```

### Longhorn volume không attach được (single node)
Đảm bảo `defaultReplicaCount: 1` trong [helm-values/longhorn/values.yaml](helm-values/longhorn/values.yaml).

---

## Checklist hoàn thành

- [ ] Prerequisites node (iscsid, vm.max_map_count)
- [ ] Repo đã push lên Git, URL đã thay trong tất cả YAML
- [ ] ArgoCD đã kết nối được repo
- [ ] Tất cả Secrets đã tạo (§4)
- [ ] `kubectl apply -f gitops/apps/root-app.yaml` đã chạy
- [ ] Tất cả ArgoCD Applications ở trạng thái Synced + Healthy
- [ ] DNS records đã thêm
- [ ] CA cert đã được trust trên node (cho Harbor/Docker)
- [ ] User `grafana_ro` đã tạo trên OpenProject PostgreSQL
- [ ] Webhook OpenProject → n8n đã cấu hình
- [ ] Longhorn backup target trỏ về CMC S3
- [ ] Test restore backup ít nhất 1 lần
