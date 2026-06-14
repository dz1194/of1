# Resource Requirements & Installation Plan

> **Mục tiêu:** Cài 7 tool trên on-prem Kubernetes với resource **tối thiểu** (lab / small-prod, 1 replica mỗi component, no-HA).
> **Quy ước:** `requests` = mức cấp phát đảm bảo (sàn để scheduler đặt pod). `limits` = trần chống pod ăn tài nguyên vô tội vạ. Đây là **starting point**, tune lại theo `kubectl top` sau khi chạy thật.
> **DB:** **Không** dùng external DB. **SonarQube** dùng bundled PostgreSQL (sub-chart), **Harbor** dùng internal database. Các tool còn lại không cần DB.

---

## 1. Tổng quan kiến trúc (Architecture Overview)

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Layer                         │
│                                                               │
│   Jenkins      SonarQube         Harbor         Argo CD       │
│   (no DB)    ┌──────────┐    ┌──────────────┐   (no DB,       │
│              │ +bundled │    │ +internal DB │    Redis)       │
│              │ Postgres │    │ +internal    │                 │
│              └──────────┘    │  Redis       │                 │
│                              └──────┬───────┘                 │
└─────────────────────────────────────┼────────────────────────┘
                                       │ S3 backend
┌──────────────────┬───────────────────▼───────────────────────┐
│                  ▼     Storage Layer (LIVE — trên cluster)    │
│        ┌──────────────┐              ┌──────────────────┐     │
│        │   Longhorn   │              │  self-host MinIO │     │
│        │ (Block / PVC)│              │  (Object / S3)   │     │
│        └──────────────┘              └──────────────────┘     │
│         RWO volumes cho mọi          - Harbor registry backend│
│         StatefulSet/PVC              - app object storage     │
│         (default StorageClass)                                │
└───────┬──────────────────────────────────────┬───────────────┘
        │ pg_dump (CronJob)                      │ Longhorn backup target
        │ Jenkins home dump                      │
        ▼                                        ▼
┌────────────────────────────────────────────────────────────────┐
│      BACKUP / DR — CMC S3 (OFF-SITE, khác failure domain)       │
│      endpoint: https://s3.<region>.cloud.cmctelecom.vn          │
│      s3://<backup-bucket>  (versioning + lifecycle + path-style) │
│      → mất node/cluster/đĩa: backup vẫn an toàn trên CMC Cloud   │
└────────────────────────────────────────────────────────────────┘
```

> **Phân biệt 2 S3 (quan trọng):** *self-host MinIO* = LIVE storage (runtime, trên cluster). *CMC S3* = BACKUP target (off-site, S3-compatible của CMC Cloud). Hai instance riêng, không dùng chung failure domain. KHÔNG đặt Longhorn backup target trỏ về MinIO (sẽ tạo circular dependency vì MinIO chạy trên Longhorn) — backup target luôn là CMC S3.

**Điểm tích hợp tiết kiệm resource:**
- Harbor dùng **MinIO (S3)** làm registry storage backend. **Lưu ý:** điều này KHÔNG tiết kiệm byte thô (image layer vẫn nằm trên đĩa nơi MinIO chạy). Lợi ích thật là: (a) registry scale nhiều replica được vì object store giống RWX, trong khi Longhorn PVC là RWO chỉ 1 replica; (b) tránh replication amplification của Longhorn khi `replica>1`; (c) tiering — cho MinIO chạy trên local disk rẻ, dành Longhorn replicated volume cho stateful data cần HA (DB, Jenkins home).
- Harbor + SonarQube mỗi tool tự chạy DB nội bộ → cài 1 phát xong, không phụ thuộc operator ngoài.
- Longhorn cấp toàn bộ PVC (RWO) cho các StatefulSet → set làm **default StorageClass**. Backup target của Longhorn trỏ ra **CMC S3** (off-site), không phải MinIO. **Giữ Longhorn dù mới 1 node** vì có kế hoạch mở rộng — `replica=1` bây giờ, bump lên `2-3` khi thêm node mà không phải migrate storage.

---

## 2. Bảng resource tối thiểu (Minimum Resource Table)

> Nguyên tắc limit: **RAM** non-compressible → vượt limit = OOMKilled, đặt có headroom. **CPU** compressible → vượt chỉ throttling; workload burst (Jenkins) có thể bỏ CPU limit.

### Storage layer (cài trước)

| Tool | Component | CPU req→limit | RAM req→limit | Storage | Ghi chú |
|------|-----------|--------------:|--------------:|---------|---------|
| **Longhorn** | longhorn-manager (DaemonSet) | 100m→200m | 128Mi→256Mi | — | mỗi node |
| | instance-manager (per node) | 200m→*(none)* | 256Mi→256Mi | — | reserve engine/replica |
| | longhorn-ui + driver | 100m→200m | 128Mi→256Mi | — | 1 lần |
| | **Disk thực** | — | — | **≥ 50Gi / node** | mount point cho replica data |
| **MinIO** | server (standalone, single-drive) | 250m→1000m | 512Mi→1Gi | **50Gi** | min cho lab; prod cần ≥4 drive |

### Application layer

| Tool | Component | CPU req→limit | RAM req→limit | Storage | DB |
|------|-----------|--------------:|--------------:|---------|:--:|
| **Jenkins** | controller | 500m→1000m | 1Gi→2Gi | **10Gi** (`JENKINS_HOME`) | ❌ |
| | agent (ephemeral) | 250m→1000m | 512Mi→2Gi | — (emptyDir) | ❌ |
| **SonarQube** | sonarqube (web+compute+ES) | 500m→1000m | 2Gi→4Gi | 5Gi (data+ext) | bundled |
| | **postgresql (bundled)** | 250m→500m | 512Mi→512Mi | 8Gi | — |
| **Harbor** | core | 100m→500m | 256Mi→512Mi | — | |
| | registry | 100m→500m | 256Mi→512Mi | — (dùng MinIO S3) | |
| | jobservice | 100m→500m | 256Mi→512Mi | 1Gi (logs) | |
| | portal | 50m→200m | 128Mi→256Mi | — | |
| | **database (internal)** | 250m→500m | 512Mi→512Mi | 1Gi | bundled |
| | **redis (internal)** | 100m→200m | 128Mi→256Mi | 1Gi | |
| | trivy | 200m→1000m | 512Mi→1Gi | 5Gi (vuln DB cache) | |
| **Argo CD** | application-controller | 250m→1000m | 512Mi→1Gi | — | ❌ |
| | repo-server | 250m→1000m | 256Mi→1Gi | — | |
| | server (API/UI) | 100m→500m | 256Mi→512Mi | — | |
| | redis | 100m→200m | 128Mi→256Mi | — | |
| | applicationset + notifications | 100m→500m | 128Mi→256Mi | — | |

> **Stateful nên để Guaranteed QoS:** với bundled Postgres (Sonar) và Harbor database, set `request == limit` cho RAM → pod vào class Guaranteed, được evict sau cùng khi node memory pressure. DB bị evict giữa chừng là thảm họa.

---

## 3. Tổng hợp footprint (Capacity Summary)

| Hạng mục | CPU requests | RAM requests | Storage (PVC) |
|----------|-------------:|-------------:|--------------:|
| Longhorn (1 node) | ~0.4 | ~0.5Gi | — (dùng disk thật) |
| MinIO | 0.25 | 0.5Gi | 50Gi |
| Jenkins (controller, không tính agent) | 0.5 | 1Gi | 10Gi |
| SonarQube (app + bundled Postgres) | 0.75 | 2.5Gi | 13Gi |
| Harbor (toàn bộ, gồm internal DB + Redis) | ~1.0 | ~2.05Gi | 8Gi |
| Argo CD (toàn bộ) | ~0.9 | ~1.4Gi | — |
| **TỔNG (xấp xỉ)** | **~3.8 vCPU** | **~7.95 GiB** | **~81 GiB PVC** |

> **Khuyến nghị cluster tối thiểu:**
> - **1 node all-in-one:** 8 vCPU / 16 GiB RAM / 150 GiB disk (chừa dư cho OS + kube-system + burst Jenkins build + ES heap Sonar).
> - **3 node nhỏ (khuyến nghị cho Longhorn replica 2-3):** mỗi node 4 vCPU / 8 GiB / 80 GiB disk.
>
> Longhorn mặc định 3 replica/volume → nếu chỉ 1 node phải set `numberOfReplicas: 1` (no redundancy). Tiêu chí "tối thiểu nhất" + chấp nhận no-HA: replica = 1.

---

## 4. Prerequisites (kiểm tra trước khi cài)

```bash
# 1. SonarQube yêu cầu vm.max_map_count (Elasticsearch nhúng) — set trên MỌI node
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf
# (hoặc dùng initContainer privileged trong Helm values)

# 2. Longhorn yêu cầu open-iscsi + nfs-common trên mọi node
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# 3. Kiểm tra LoadBalancer (MetalLB) / IngressController đã sẵn sàng cho Harbor & UI
kubectl get pods -n metallb-system
kubectl get pods -n ingress-nginx   # hoặc cilium ingress

# 4. Helm + repo
helm version

# 5. Backup target CMC S3 — tạo bucket + lấy key (chạy 1 lần, phía CMC Cloud)
#    - Endpoint theo region, ví dụ: https://s3.hn-1.cloud.cmctelecom.vn  (region hn-1)
#    - Bucket riêng cho backup, BẬT Versioning + lifecycle (expire bản cũ) để kiểm soát cost
#    - Access Key ID / Secret Access Key lấy từ CMC Portal v2
#    - LƯU Ý: CMC S3 là S3-compatible (không phải AWS) → mọi tool phải khai:
#        * custom endpoint  (--endpoint-url / AWS_ENDPOINTS / s3Url)
#        * path-style addressing  (s3ForcePathStyle=true)
#    - Cluster cần outbound internet tới endpoint CMC S3
#    - Lưu key vào K8s Secret (KHÔNG hardcode vào values/manifest)
```

---

## 5. Tóm tắt các step cài đặt (Installation Steps — đúng thứ tự dependency)

### Phase 0 — Storage foundation (BẮT BUỘC trước tiên)
1. **Cài Longhorn** (`helm install longhorn longhorn/longhorn -n longhorn-system`).
   - Set `defaultSettings.defaultReplicaCount=1` (tối thiểu) hoặc `2-3` nếu ≥3 node.
   - Đặt Longhorn StorageClass làm **default**:
     `kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`
   - Verify: `kubectl get sc`, tạo PVC test.

### Phase 1 — Object storage
2. **Cài MinIO** (standalone, 1 drive, PVC 50Gi trên Longhorn).
   - Tạo bucket cho Harbor registry: `harbor-registry`.
   - Lưu `accessKey` / `secretKey` vào Secret (dùng lại ở Harbor).

### Phase 2 — Registry
3. **Cài Harbor** (`helm install harbor harbor/harbor`).
   - `database.type=internal` → Harbor tự chạy Postgres nội bộ (PVC 1Gi).
   - `redis.type=internal` → Harbor tự chạy Redis nội bộ.
   - `persistence.imageChartStorage.type=s3` → trỏ về **MinIO** (endpoint, bucket `harbor-registry`, key).
   - `expose.type=ingress` + TLS (cert tự ký hoặc cert-manager).
   - Verify: `docker login`, push 1 image test.

### Phase 3 — Code quality
4. **Cài SonarQube** (`helm install sonarqube sonarqube/sonarqube`).
   - `postgresql.enabled=true` → dùng bundled PostgreSQL (PVC 8Gi).
   - Đảm bảo `vm.max_map_count` (Phase 0 prereq), nếu không ES không start.
   - Set heap `-Xmx512m` cho web/compute (tối thiểu, tránh OOM trên RAM thấp).
   - Verify: login UI, tạo 1 project.

### Phase 4 — CI
5. **Cài Jenkins** (`helm install jenkins jenkins/jenkins`).
   - PVC 10Gi (Longhorn) cho `JENKINS_HOME`.
   - Agent dùng `kubernetes` plugin (pod ephemeral) → **không** chiếm resource cố định.
   - **Không cần** DB.
   - Verify: chạy 1 pipeline job test.

### Phase 5 — GitOps (cài cuối, rồi quản lý mọi thứ qua Git)
6. **Cài Argo CD** (`helm install argocd argo/argo-cd`).
   - Lightweight, không cần PVC/DB (state ở K8s API + Redis nội bộ).
   - Verify: login UI, sync 1 app test.
   - **Best practice:** sau khi Argo CD chạy, migrate dần các Helm release trên thành **Application manifests** (App-of-apps + sync-wave) → Git làm single source of truth.

> **Lưu ý thứ tự (tuỳ chọn GitOps-first):** Argo CD không cần PVC/DB nên có thể cài **rất sớm** (bước 2) rồi dùng **sync-wave** để Argo CD tự deploy phần còn lại theo đúng dependency: `wave 0` Longhorn/MinIO → `wave 1` Harbor/Sonar → `wave 2` Jenkins. Argo CD chỉ sync wave sau khi wave trước **Healthy**, nên ordering vẫn được tôn trọng mà không cần làm tay.

### Phase 6 — Backup & DR (sang CMC S3, off-site)
7. **Cấu hình backup ra CMC S3** (không HA → backup là tuyến phòng thủ chính).
   - **Longhorn backup target = CMC S3:** đặt `s3://<bucket>@<region>/` (vd `s3://platform-backup@hn-1/`).
     Secret credential phải có 3 key: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, và
     **`AWS_ENDPOINTS=https://s3.hn-1.cloud.cmctelecom.vn`** (chính key này trỏ Longhorn về CMC thay vì AWS).
     KHÔNG trỏ về MinIO (circular dependency — MinIO chạy trên Longhorn).
     Set RecurringJob (snapshot + backup định kỳ) cho PVC quan trọng: `JENKINS_HOME`, Harbor/Sonar DB.
   - **DB → app-consistent dump:** CronJob chạy `pg_dump` cho Harbor + Sonar → upload bằng
     `aws s3 cp --endpoint-url https://s3.hn-1.cloud.cmctelecom.vn` hoặc `mc` (alias custom endpoint).
   - **Jenkins:** dùng Longhorn backup của PVC, hoặc ThinBackup plugin → CMC S3 (gồm config + credentials).
   - **Velero (nếu dùng):** plugin AWS với `s3Url=https://s3.hn-1.cloud.cmctelecom.vn`, `region=hn-1`,
     **`s3ForcePathStyle: true`** (bắt buộc cho S3-compatible non-AWS).
   - **Argo CD: KHÔNG cần backup** — state ở Git + K8s, Git chính là source of truth.
   - **Test restore định kỳ** — backup chưa restore thử = backup chưa tồn tại.

---

## 6. Production Safety Notes (lưu ý khi lên thật)

| # | Lưu ý | Severity |
|---|-------|----------|
| 1 | Config tối thiểu này **no-HA** (bundled DB 1 replica, MinIO single-drive, Longhorn replica=1) → mất node = mất data. Chấp nhận cho lab; prod phải tăng replica. | 🔴 Critical |
| 2 | Bundled DB của Harbor & Sonar là **2 Postgres riêng** → phải backup riêng từng cái (pg_dump cron → **CMC S3**). Đã có tuyến backup off-site nên rủi ro logic-error được che; cân nhắc external DB khi cần HA/PITR. | 🟡 Warning |
| 3 | **Không** hardcode credentials (kể cả CMC S3 key) vào values.yaml/manifest — dùng Secret / External Secrets / Vault. | 🔴 Critical |
| 4 | SonarQube ES heap thấp dễ `OOMKilled` khi scan project lớn → theo dõi `kubectl top pod`, tăng RAM khi cần. | 🟡 Warning |
| 5 | Jenkins build burst CPU/RAM cao → cân nhắc bỏ CPU limit cho agent (tránh throttling), giữ RAM limit. | 🟡 Warning |
| 6 | Backup target là **CMC S3** (off-site, khác failure domain) — KHÔNG trỏ Longhorn backup target về self-host MinIO (circular dependency). Vì là S3-compatible non-AWS: bắt buộc khai `AWS_ENDPOINTS`/`s3ForcePathStyle`. Bật Versioning để chống ghi đè/ransomware. | 🔴 Critical |
| 7 | Harbor + MinIO S3: bật TLS endpoint, không dùng HTTP plaintext giữa registry ↔ MinIO. | 🟢 Suggestion |

---

## 7. Tài liệu tham khảo (Official Docs)

- Longhorn: https://longhorn.io/docs/
- MinIO Operator/Helm: https://min.io/docs/minio/kubernetes/
- Harbor Helm (internal DB + S3 backend): https://github.com/goharbor/harbor-helm
- SonarQube Helm (bundled postgresql): https://github.com/SonarSource/helm-chart-sonarqube
- Jenkins Helm: https://github.com/jenkinsci/helm-charts
- Argo CD: https://argo-cd.readthedocs.io/
- Longhorn backup to S3: https://longhorn.io/docs/latest/snapshots-and-backups/backup-and-restore/set-backup-target/
- CMC S3 (backup target, tích hợp S3-client): https://cmccloud.vn/document/s3-standard/huong-dan/tich-hop-cmc-s3-voi-cac-s3-client
