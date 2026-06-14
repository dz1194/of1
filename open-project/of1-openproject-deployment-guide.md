# OF1 — OpenProject Community: Hướng dẫn Triển khai & Cấu hình End-to-End

**Phiên bản:** Draft 1.0 · **Ngày:** 2026-06-11
**Phạm vi:** Product intake → Prioritization → Delivery tracking → Flow metrics & Bottleneck detection
**Stack:** OpenProject Community (core) · n8n (automation/intake) · Grafana + PostgreSQL (metrics) · Apache DevLake (DORA, optional)

---

## 1. Kiến trúc tổng thể

```
┌─────────────────────────────────────────────────────────────────┐
│  NGUỒN YÊU CẦU                                                  │
│  Tập đoàn (Bee) · Domain Owners · Công ty thành viên · Nội bộ  │
└──────────┬─────────────────┬────────────────────┬───────────────┘
           │ Email           │ Web Form (n8n)     │ Direct (account)
           ▼                 ▼                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  OPENPROJECT COMMUNITY (self-hosted, Docker)                    │
│  · Project "00 - Intake" (triage queue)                         │
│  · Product projects per squad (Freight / Warehouse / Customs)   │
│  · Delivery projects per công ty thành viên (từ template)       │
│  · Custom types: Idea / Feature / Bug / Improvement / Delivery  │
│  · Workflow states = phases của AI Product Factory pipeline     │
└──────┬──────────────────────────────┬───────────────────────────┘
       │ Webhooks + API v3            │ PostgreSQL (read replica
       ▼                              │  hoặc read-only user)
┌──────────────────┐                  ▼
│  n8n             │        ┌──────────────────────┐
│  · Routing       │        │  GRAFANA             │
│  · Notifications │        │  · Cycle time/phase  │
│  · Auto-assign   │        │  · WIP & Aging       │
│  · SLA alerts    │        │  · Throughput        │
└──────────────────┘        │  · Bottleneck view   │
                            └──────────────────────┘
       (Optional) GitLab/GitHub + CI ──► Apache DevLake ──► DORA dashboards
```

**Nguyên tắc thiết kế:**
- OpenProject CE là **single source of truth** cho mọi work item từ lúc tiếp nhận đến lúc deploy.
- Automation KHÔNG nằm trong OpenProject (custom actions là Enterprise-only) mà nằm ở **n8n** qua API v3 + webhooks.
- Metrics KHÔNG dùng report built-in mà query thẳng **PostgreSQL journals** — chính xác hơn và đo được time-in-status.

---

## 2. Triển khai hạ tầng (DevOps)

### 2.1. Sizing đề xuất

| Service | VM/Container | CPU | RAM | Disk |
|---|---|---|---|---|
| OpenProject (all-in-one compose) | VM 1 | 4 vCPU | 8 GB | 60 GB SSD |
| n8n + Grafana | VM 2 (hoặc chung VM 1) | 2 vCPU | 4 GB | 20 GB |
| DevLake (nếu dùng) | VM 2 | 2 vCPU | 4 GB | 40 GB |

Với 30 dev + ~10–15 stakeholder accounts, cấu hình trên dư tải.

### 2.2. Cài OpenProject bằng Docker Compose

```bash
git clone https://github.com/opf/openproject-deploy --depth=1 --branch=stable/16 openproject
cd openproject/compose
# Kiểm tra branch stable mới nhất tại repo trước khi clone
```

Tạo file `.env`:

```env
OPENPROJECT_HTTPS=true
OPENPROJECT_HOST__NAME=openproject.of1.internal
OPENPROJECT_HSTS=true
PORT=127.0.0.1:8080
DATABASE_URL=postgres://postgres:<STRONG_PASSWORD>@db/openproject?pool=20
OPENPROJECT_RAILS__MAX__THREADS=16
# SMTP cho notification
OPENPROJECT_EMAIL__DELIVERY__METHOD=smtp
OPENPROJECT_SMTP__ADDRESS=smtp.of1.internal
OPENPROJECT_SMTP__PORT=587
OPENPROJECT_SMTP__DOMAIN=of1.vn
```

Khởi chạy:

```bash
docker compose pull
docker compose up -d
docker compose logs -f web   # đợi migration xong
```

Đặt sau reverse proxy (nginx/Traefik/Caddy) với TLS. Lưu ý header `X-Forwarded-Proto: https` để OpenProject sinh URL đúng.

### 2.3. Backup & Upgrade

**Backup hằng đêm (cron):**

```bash
#!/usr/bin/env bash
set -euo pipefail
TS=$(date +%Y%m%d-%H%M)
docker compose exec -T db pg_dump -U postgres openproject | gzip > /backup/op-db-$TS.sql.gz
tar czf /backup/op-assets-$TS.tar.gz -C /var/lib/docker/volumes/compose_opdata/_data .
find /backup -name 'op-*' -mtime +30 -delete
```

**Upgrade:** `git pull` branch stable → `docker compose pull` → `docker compose up -d`. Migration tự chạy. **Luôn backup trước khi upgrade.** Test upgrade trên staging instance trước khi áp lên production (dựng staging bằng cách restore backup vào compose project thứ hai).

### 2.4. Read-only DB user cho Grafana

```sql
CREATE ROLE grafana_ro LOGIN PASSWORD '<password>';
GRANT CONNECT ON DATABASE openproject TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
```

Grafana kết nối qua datasource PostgreSQL với user này. Tuyệt đối không cấp quyền write.

---

## 3. Cấu trúc Project & Work Package Types

### 3.1. Project hierarchy

```
OF1 Portfolio (parent, chỉ để roll-up)
├── 00 - Intake                  ← mọi yêu cầu mới đổ vào đây
├── Freight Forwarding           ← product project / squad
├── Warehouse
├── Customs & Finance
├── Shared Platform
├── Delivery - <Company A>       ← tạo từ template mỗi khi onboard
└── Delivery - <Company B>
```

- **00 - Intake**: queue duy nhất. Domain Owners / công ty thành viên chỉ thấy project này (+ project delivery của riêng họ).
- **Product projects**: backlog + sprint của từng squad. Work item được *move* từ Intake sang sau khi triage.
- **Delivery projects**: tạo từ **project template** (CE hỗ trợ) chứa sẵn cấu trúc work packages chuẩn cho customize/config/integration — đảm bảo mọi đợt delivery đo được bằng cùng một thước.

### 3.2. Custom Types

Admin → Work packages → Types. Tạo 5 types:

| Type | Màu | Dùng cho |
|---|---|---|
| **Request** | Xám | Mọi item mới ở Intake, chưa phân loại |
| **Feature** | Xanh dương | Tính năng mới / cải thiện tính năng |
| **Bug** | Đỏ | Lỗi |
| **Improvement** | Xanh lá | Cải tiến kỹ thuật, tech debt |
| **Delivery Task** | Cam | Customize / config / integration cho công ty thành viên |

Khi triage, Product Lead đổi type từ Request → type đúng và move sang project đích.

### 3.3. Statuses = Phases (quan trọng nhất cho metrics)

Admin → Work packages → Status. Đây là xương sống của việc đo phase — mỗi status là một phase cần đo:

```
New → Triaged → In Analysis → Ready → In Development → In Review → In UAT → Deployed → Closed
                                                                              ↘ Rejected (terminal)
```

Quy ước đo:
- **Reaction time** = New → Triaged
- **Analysis time** = Triaged → Ready (đo hiệu quả AI Product Factory + Domain Owners)
- **Dev cycle time** = Ready → In Review
- **Validation time** = In Review → Deployed
- **End-to-end lead time** = New → Deployed

Workflow (Admin → Work packages → Workflow) cấu hình transition cho phép theo từng type × role. Giữ workflow tuyến tính + cho phép quay lui 1 bước (vd In Review → In Development) để dữ liệu sạch.

⚠️ **Kỷ luật vận hành:** metrics chỉ đúng nếu status được cập nhật đúng lúc. Đưa vào Definition of Done của squad: "chuyển status ngay khi đổi phase". n8n có thể nhắc item đứng yên quá N ngày (xem §6).

### 3.4. Custom Fields

Admin → Custom fields → Work packages:

| Field | Kiểu | Mục đích |
|---|---|---|
| `Requesting Org` | List (Bee / Company A / Company B / Internal) | Phân tích yêu cầu đến từ đâu, SLA theo nguồn |
| `Business Value` | Integer 1–5 | Input cho prioritization của Steering Board |
| `Effort Class` | List (S / M / L / XL) | Ước lượng thô khi triage, trước khi estimate chi tiết |
| `Target Release` | Version (built-in) | Gắn vào release plan |

Priority dùng field **Priority** built-in (Low / Normal / High / Immediate). Quy ước: chỉ Product Lead và Steering Board được set High/Immediate (enforce bằng role permission "Edit work packages" + soát qua n8n alert nếu ai khác đổi).

---

## 4. Roles & Permissions

Admin → Users and permissions → Roles. Tạo thêm 2 roles ngoài mặc định:

**Role `Requester`** (cho Domain Owners, đầu mối công ty thành viên):
- ✅ View work packages, Add work packages, Add comments, View own time entries
- ❌ Edit work packages của người khác, Move, Delete, Manage versions
- Gán vào project **00 - Intake** và project **Delivery - <Company X>** của họ. Họ không thấy backlog product nội bộ.

**Role `Steering`** (Steering Board, Operational Director):
- ✅ View tất cả, Edit priority, Comment
- ❌ Thao tác delivery chi tiết
- Gán ở project **OF1 Portfolio** (parent) với inherit xuống — họ thấy roll-up toàn cảnh.

Squad members dùng role `Member` mặc định trong project của squad mình. 4 Lead (Product / Engineering / Shared Platform / AI & Data Platform) dùng `Project admin` trong domain tương ứng.

---

## 5. Intake — 3 kênh tiếp nhận

### Kênh 1: Tài khoản trực tiếp (Domain Owners)
Domain Owners có account với role Requester, tạo work package type **Request** trong **00 - Intake**. Đơn giản nhất, ưu tiên dùng cho người tương tác thường xuyên.

### Kênh 2: Incoming email
OpenProject CE hỗ trợ tạo work package từ email. Cấu hình IMAP polling qua cron trong container:

```bash
docker compose exec web bundle exec rake redmine:email:receive_imap \
  host='imap.of1.internal' port=993 ssl=1 \
  username='intake@of1.vn' password='<pw>' \
  project=intake tracker=Request \
  allow_override=type,priority unknown_user=accept no_permission_check=1
```

Chạy mỗi 5 phút bằng cron trên host. Email gửi tới `intake@of1.vn` → tự thành Request trong Intake, subject = title, body = description. Phù hợp cho stakeholder bên Bee không muốn học tool mới.

> Cân nhắc: `unknown_user=accept` mở rủi ro spam nếu mailbox lộ ra ngoài — nếu chỉ dùng nội bộ tập đoàn thì chấp nhận được; nếu không, đổi sang `unknown_user=default` và whitelist domain ở mail server.

### Kênh 3: Web form qua n8n (công ty thành viên)
n8n Form Trigger (hoặc Formbricks nếu cần form đẹp hơn) → node HTTP Request gọi OpenProject API v3:

```
POST https://openproject.of1.internal/api/v3/projects/intake/work_packages
Authorization: Basic apikey:<API_TOKEN_của_service_account>
Content-Type: application/json

{
  "subject": "{{form.title}}",
  "description": { "raw": "{{form.detail}}\n\n---\nNgười gửi: {{form.name}} ({{form.email}})" },
  "_links": {
    "type": { "href": "/api/v3/types/<id_Request>" },
    "priority": { "href": "/api/v3/priorities/<id_Normal>" }
  },
  "customField<N>": "{{form.company}}"
}
```

Form có dropdown bắt buộc: Loại yêu cầu (Ý tưởng / Bug / Tính năng / Delivery), Công ty, Mức độ ảnh hưởng. n8n map vào custom fields. Sau khi tạo, n8n gửi email xác nhận kèm link work package cho người gửi — họ theo dõi tiến độ mà không cần account (hoặc cấp account Requester nếu muốn họ comment).

### Triage cadence
Product Lead (hoặc trực ban triage luân phiên) xử lý queue Intake **mỗi ngày làm việc**: phân loại type, set Requesting Org + Effort Class + Business Value sơ bộ, move sang project đích, status → Triaged. Mục tiêu SLA: 100% item được triage trong 2 ngày làm việc (đo được bằng Reaction time ở §7).

---

## 6. Automation với n8n (bù Custom Actions của Enterprise)

Bật webhook: Admin → API and webhooks → thêm webhook trỏ về n8n endpoint, events: work package created/updated.

Các flow đề xuất (theo thứ tự ưu tiên triển khai):

1. **Intake notification**: Request mới → post vào channel Slack/Teams của Product Lead kèm link.
2. **SLA triage alert**: cron mỗi sáng query API các item status=New quá 2 ngày → nhắc.
3. **Stale item alert**: item ở In Development / In Review quá 5 ngày không update → nhắc assignee + Engineering Lead. (Đây là bottleneck detector real-time, bổ trợ cho dashboard.)
4. **Priority guard**: webhook updated → nếu priority đổi sang High/Immediate bởi user ngoài danh sách cho phép → revert qua API + thông báo.
5. **Delivery onboarding**: form "Công ty mới" → n8n gọi API copy project từ template `Delivery Template` → gán Requester role cho đầu mối công ty đó.
6. **GitLab/GitHub sync** (giai đoạn 2): commit message chứa `OP#1234` → n8n comment link MR vào work package; MR merged → chuyển status In Review.

---

## 7. Metrics & Bottleneck — Grafana trên PostgreSQL

OpenProject ghi mọi thay đổi vào bảng `journals` (+ bảng data đi kèm theo journable type). Status transitions nằm trong journal diff của work package. Schema chi tiết thay đổi nhẹ giữa các major version — **bước đầu tiên của DevOps là verify schema trên instance đã deploy**:

```sql
\d journals
\d work_package_journals
```

### 7.1. Query nền: lịch sử chuyển status

Ý tưởng: với mỗi work package, lấy chuỗi journal entries kèm `status_id` tại từng thời điểm, dùng `LAG()` để phát hiện transition và `LEAD()` để tính thời gian đứng ở mỗi status.

```sql
WITH status_history AS (
  SELECT
    j.journable_id            AS wp_id,
    j.created_at,
    wpj.status_id,
    LAG(wpj.status_id)  OVER w AS prev_status_id,
    LEAD(j.created_at)  OVER w AS next_change_at
  FROM journals j
  JOIN work_package_journals wpj ON wpj.journal_id = j.id
  WHERE j.journable_type = 'WorkPackage'
  WINDOW w AS (PARTITION BY j.journable_id ORDER BY j.created_at, j.version)
),
transitions AS (
  SELECT
    wp_id,
    status_id,
    created_at                                        AS entered_at,
    COALESCE(next_change_at, NOW())                   AS left_at,
    EXTRACT(EPOCH FROM COALESCE(next_change_at, NOW()) - created_at) / 86400.0
                                                      AS days_in_status
  FROM status_history
  WHERE prev_status_id IS DISTINCT FROM status_id
)
SELECT
  s.name                                   AS phase,
  COUNT(*)                                 AS samples,
  ROUND(AVG(t.days_in_status)::numeric, 1) AS avg_days,
  ROUND(PERCENTILE_CONT(0.85) WITHIN GROUP (ORDER BY t.days_in_status)::numeric, 1)
                                           AS p85_days
FROM transitions t
JOIN statuses s ON s.id = t.status_id
JOIN work_packages wp ON wp.id = t.wp_id
WHERE t.entered_at >= NOW() - INTERVAL '90 days'
GROUP BY s.name, s.position
ORDER BY s.position;
```

> Lưu ý: query trên là khung khởi điểm. Tùy version, `work_package_journals` có thể join qua `journals.data_id` thay vì `journal_id` — DevOps kiểm tra FK thực tế rồi chỉnh. Mỗi journal entry chứa snapshot, nên cần `prev_status_id IS DISTINCT FROM status_id` để lọc đúng transition.

### 7.2. Dashboards đề xuất (4 panel chính)

1. **Cycle time per phase** (bar chart, query trên, filter theo project/type/Requesting Org): phase nào có avg + p85 cao nhất = nghẽn. So sánh p85 với avg để thấy độ phân tán — p85 >> avg nghĩa là có outlier kẹt dài.
2. **WIP per phase** (stat/bar): đếm work package theo status hiện tại, group theo squad. WIP dồn ở một phase + cycle time phase đó tăng = nghẽn xác nhận.
3. **Aging WIP** (table): các item đang mở, sắp theo số ngày ở status hiện tại giảm dần — feeding trực tiếp cho weekly review của các Lead.
4. **Throughput & Lead time trend** (time series, weekly): số item Deployed/Closed mỗi tuần + median end-to-end lead time. Đây là số liệu báo cáo Steering Board: trend cải thiện hay xấu đi sau mỗi thay đổi quy trình.

Tách dashboard theo audience: **Squad view** (filter project), **Steering view** (toàn portfolio, group theo Requesting Org để thấy yêu cầu của công ty nào đang chậm).

### 7.3. DORA (giai đoạn 2, optional)

Khi muốn nối flow metrics (process) với delivery performance (engineering), dựng Apache DevLake: kéo data từ GitLab/GitHub + CI để ra deployment frequency, lead time for changes, change failure rate, kèm benchmark Elite/High/Medium/Low. DevLake không hỗ trợ OpenProject native — dùng incoming webhook của DevLake để n8n đẩy incident (Bug có priority High) sang nếu cần change failure rate đầy đủ.

---

## 8. Kế hoạch rollout 4 tuần

| Tuần | Việc | Owner |
|---|---|---|
| 1 | Dựng OpenProject staging + production, TLS, backup, restore test. Tạo types/statuses/custom fields/roles theo §3–4 | DevOps |
| 2 | Dựng n8n, flow 1–2 (intake notify + SLA). Cấu hình incoming email. Tạo Delivery Template project. Import backlog hiện tại (CSV/API) | DevOps + Product Lead |
| 2–3 | Pilot với 1 squad (đề xuất squad có Domain Owner hợp tác tốt nhất). Onboard Domain Owners vào kênh intake | Product Lead |
| 3 | Grafana datasource + 4 dashboard §7.2, verify số liệu với pilot squad | DevOps + Engineering Lead |
| 4 | Rollout toàn bộ squads + công ty thành viên. Chốt triage cadence + status discipline vào Operating Principles. Retro sau 2 sprint | 4 Leads |

**Tiêu chí thành công sau 60 ngày:** 100% yêu cầu mới đi qua Intake (không còn kênh ngách qua chat/email cá nhân); dashboard cycle time có đủ sample để chỉ ra phase nghẽn nhất; Steering Board dùng Steering view trong ít nhất 2 phiên review.

---

## 9. Rủi ro & Lưu ý

- **Status discipline** là điểm chết của toàn bộ hệ metrics. Nếu dev gom việc rồi chuyển status một lượt cuối sprint, mọi con số đều rác. Cần enforce qua DoD + stale alert (§6.3) ngay từ pilot.
- **Schema drift khi upgrade OpenProject**: queries §7 đọc trực tiếp internal schema, có thể vỡ sau major upgrade. Quy trình: chạy lại verify schema sau mỗi major version, giữ queries trong Git repo riêng có version tag tương ứng.
- **Boards ở CE là manual**: kéo card trên board KHÔNG đổi status tự động. Train team đổi status trên work package, dùng board chỉ để nhìn. Nếu đây thành điểm đau lớn sau 3 tháng, đó là tín hiệu cân nhắc Enterprise on-premises (có thể trial 14 ngày trên chính instance CE đang chạy, downgrade tự động không mất data).
- **Email intake spam**: xem caveat §5 kênh 2.
