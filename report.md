# SRE Capstone — Production Readiness Review (PRR)

**Course:** SRE
**Team:** Alexey, Alihan, Iskander, Rauan
**Service under review:** `shop-api` (Go microservice, e-commerce demo)

---

## 1. Objective

Take a newly developed microservice (`shop-api`) and bring it through a
production-readiness review: reproducible infrastructure, automated build and
deploy, end-to-end observability with alerting, defined SLIs/SLOs, and a load
test that validates auto-scaling under traffic spikes.

The four capstone pillars map 1:1 to the rubric:

1. **IaC** — every cluster object is created by Terraform, no `kubectl apply`
   by hand.
2. **CI/CD** — every push to `main` builds a container, ships it to GHCR, and
   rolls the deployment.
3. **Observability** — Prometheus scrapes the service, Grafana renders SLI
   panels, Alertmanager routes alerts from rules grounded in the SLOs.
4. **SRE operations** — SLIs/SLOs are written down, HPA targets the SLI that
   actually correlates with latency (CPU), and Locust proves the autoscaler
   reacts to a 5× traffic surge.

## 2. Scenario

We are the SRE team for a small e-commerce backend. The product team has shipped
a Go service (`shop-api`) with a CPU-heavy endpoint (`/work`) that represents
catalogue search. Before sign-off we owe the engineering manager a written PRR
covering infrastructure, deployment automation, observability and the scaling
story.

## 3. Architecture

```
                              final/
                              ├── app/             Go shop-api + Dockerfile
                              ├── terraform/       providers, namespaces, ConfigMaps, manifests
                              ├── k8s/             Deployment/Service/HPA + Prom/Grafana/AM
                              ├── observability/   prometheus.yml, rules.yml, dashboard.json, AM cfg
                              ├── load/            locustfile.py
                              ├── .github/         CI/CD workflow
                              └── images/          screenshots

   Developer push ──▶ GitHub Actions ──▶ ghcr.io/<repo>/shop-api:sha-XXXXXXX
                                                      │
                                                      ▼
                                              kubectl set image
                                                      │
                  ┌───────────────────────────────────┴─────────────────────────────┐
                  │  ns: shop                           ns: monitoring              │
                  │  ┌──────────────┐                   ┌──────────────┐            │
                  │  │ shop-api     │◀──scrape──────────│ Prometheus   │──rules──┐  │
                  │  │ Deployment   │                   │ (NodePort    │         │  │
                  │  │ + Service    │                   │  30090)      │         │  │
                  │  │ + HPA (CPU)  │                   └──────┬───────┘         │  │
                  │  └──────┬───────┘                          │ dashboards      │  │
                  │         │                                  ▼                 ▼  │
                  │         │                          ┌──────────────┐  ┌────────────┐
                  │         └─── load test (Locust) ──▶│ Grafana      │  │ Alertmanager│
                  │                                    │ (30030)      │  │ (30093)     │
                  │                                    └──────────────┘  └────────────┘
                  └──────────────────────────────────────────────────────────────────┘
```

## 4. Tools & versions

| Tool | Version | Role |
|---|---|---|
| Terraform | 1.9 | IaC root module |
| `kubernetes` provider | ~> 2.32 | Native K8s resources (namespaces, ConfigMaps) |
| `alekc/kubectl` provider | ~> 2.1 | Server-side apply of raw YAML manifests |
| Minikube | 1.38 | Local Kubernetes cluster (Docker driver) |
| Kubernetes / `kubectl` | 1.32 | Workload runtime |
| `metrics-server` | v0.8 | Source of CPU metrics for HPA |
| Prometheus | v2.55 | Metrics + alert rule evaluation |
| Grafana | 11.2 | SLI dashboards |
| Alertmanager | v0.27 | Alert routing |
| Go | 1.24 | `shop-api` build |
| Docker / BuildKit | 27 | Image build, multi-stage |
| GitHub Actions | hosted | CI/CD |
| GHCR | hosted | Container registry |
| Locust | 2.43 | Load generator |

---

## 5. Step 1 — Infrastructure as Code (Terraform)

### 5.1 Description

Everything that lives in the cluster is materialised by a single
`terraform apply`. Two providers cooperate:

- The `hashicorp/kubernetes` provider owns the things we want strongly typed
  and lifecycle-managed (namespaces, ConfigMaps).
- The `alekc/kubectl` provider applies raw YAML for Deployments, Services and
  the HPA. Mixing the two keeps the manifests editable as plain YAML (good
  for review, copy-paste, kustomize later) while still giving the namespaces
  and configs proper Terraform identity.

All Prometheus / Grafana / Alertmanager configuration is sourced from
`observability/` and baked into ConfigMaps via `file()` so the config files
and the cluster state cannot drift.

### 5.2 Source — `terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.32" }
    kubectl    = { source = "alekc/kubectl",        version = "~> 2.1"  }
  }
}
```

### 5.3 Source — `terraform/variables.tf` (excerpt)

```hcl
variable "kube_context"      { default = "minikube" }
variable "manifests_dir"     { default = "../k8s" }
variable "observability_dir" { default = "../observability" }
variable "app_image"         { default = "shop-api:v1" }
```

State stays local (`terraform.tfstate`) for this single-cluster lab; for a
multi-environment setup the recommended next step is an S3/GCS backend with
`force_unlock` enabled.

### 5.4 Source — `terraform/main.tf` (key parts)

```hcl
resource "kubernetes_namespace_v1" "shop"       { metadata { name = "shop" } }
resource "kubernetes_namespace_v1" "monitoring" { metadata { name = "monitoring" } }

resource "kubernetes_config_map_v1" "prometheus_config" {
  metadata { name = "prometheus-config", namespace = "monitoring" }
  data = { "prometheus.yml" = file("${var.observability_dir}/prometheus/prometheus.yml") }
}

data "kubectl_path_documents" "app" { pattern = "${var.manifests_dir}/10-app-deployment.yaml" }

resource "kubectl_manifest" "app" {
  for_each   = toset(data.kubectl_path_documents.app.documents)
  yaml_body  = each.value
  depends_on = [kubernetes_namespace_v1.shop]
}
```

### 5.5 Workflow

```bash
minikube start --driver=docker --cpus=4 --memory=6g
minikube addons enable metrics-server
eval $(minikube docker-env)
docker build -t shop-api:v1 ./app

cd terraform
terraform init
terraform apply -auto-approve
```

`terraform apply` is idempotent — re-running it after a manifest edit only
diffs the affected `kubectl_manifest` resource, not the whole cluster.

---

## 6. Step 2 — CI/CD (GitHub Actions → GHCR → cluster)

### 6.1 Description

The pipeline is three stages: **build-test → docker-publish → deploy**.
The build job vets and compiles the Go binary so a broken module never ships.
`docker-publish` uses `docker/build-push-action` with GHA cache, tagging by
short SHA *and* `latest` on the default branch. `deploy` only fires on
`main`, decodes a base64 kubeconfig from a secret, and rolls the new image
with `kubectl set image` followed by `kubectl rollout status`.

The deploy uses the immutable `sha-XXXXXXX` tag, never `latest`. This is
deliberate — pinning to the SHA makes rollouts deterministic and rollbacks
trivial (`kubectl rollout undo`).

### 6.2 Source — `.github/workflows/ci-cd.yml` (key parts)

```yaml
jobs:
  build-test:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: "1.24", cache-dependency-path: app/go.sum }
      - working-directory: app
        run: |
          go vet ./...
          go build ./...

  docker-publish:
    needs: build-test
    steps:
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}/shop-api
          tags: |
            type=ref,event=branch
            type=sha,prefix=sha-
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/build-push-action@v6
        with:
          context: app
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: docker-publish
    if: github.ref == 'refs/heads/main'
    environment: production
    steps:
      - run: |
          echo "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > $HOME/.kube/config
          IMAGE="ghcr.io/${{ github.repository }}/shop-api:sha-${GITHUB_SHA::7}"
          kubectl -n shop set image deployment/shop-api shop-api="$IMAGE"
          kubectl -n shop rollout status deployment/shop-api --timeout=2m
```

### 6.3 Source — `app/Dockerfile`

```Dockerfile
FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/shop-api .

FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=builder /out/shop-api /shop-api
EXPOSE 5000
ENTRYPOINT ["/shop-api"]
```

A multi-stage build keeps the runtime image at ~15 MB. The container runs as
non-root (`uid=10001`) which is a baseline PodSecurity admission expectation.

---

## 7. Step 3 — Observability & Alerting

### 7.1 Description

Prometheus discovers `shop-api` pods through `kubernetes_sd_configs` (role:
pod, namespace: shop) and the `prometheus.io/scrape=true` annotation on the
Deployment template. The service exposes three first-class signals:

- `shop_api_http_requests_total{route,code,method}` — traffic + errors
- `shop_api_http_request_duration_seconds_bucket{route}` — latency
- `shop_api_inflight_requests` — saturation

That gives us the RED method (Rate, Errors, Duration) plus saturation, which
is what the SLOs in §8 are built on. Recording rules pre-aggregate the
common queries so the dashboard and the alerts share the same definitions.

### 7.2 Source — `observability/prometheus/prometheus.yml` (scrape config)

```yaml
scrape_configs:
  - job_name: "shop-api"
    kubernetes_sd_configs:
      - role: pod
        namespaces: { names: ["shop"] }
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_ip, __tmp_metrics_port]
        action: replace
        regex: ([^:]+);(\d+)
        replacement: $1:$2
        target_label: __address__
```

### 7.3 Source — `observability/prometheus/rules.yml`

```yaml
groups:
  - name: shop-api-slo
    interval: 30s
    rules:
      - record: shop_api:request_rate5m
        expr: sum(rate(shop_api_http_requests_total[5m])) by (route)
      - record: shop_api:error_rate5m
        expr: |
          sum(rate(shop_api_http_requests_total{code=~"5.."}[5m]))
          / clamp_min(sum(rate(shop_api_http_requests_total[5m])), 1e-9)
      - record: shop_api:latency_p95_5m
        expr: histogram_quantile(0.95,
                sum(rate(shop_api_http_request_duration_seconds_bucket[5m])) by (le, route))

      - alert: ShopApiHighErrorRate
        expr: shop_api:error_rate5m > 0.05
        for: 2m
        labels: { severity: critical, slo: availability }
        annotations:
          summary: "shop-api 5xx rate > 5%"

      - alert: ShopApiHighLatency
        expr: histogram_quantile(0.95,
                sum(rate(shop_api_http_request_duration_seconds_bucket{route="/work"}[5m])) by (le)) > 1
        for: 5m
        labels: { severity: warning, slo: latency }
```

### 7.4 Source — `observability/alertmanager/alertmanager.yml`

```yaml
route:
  receiver: default
  group_by: ["alertname", "slo"]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  routes:
    - matchers: [severity = "critical"]
      receiver: oncall
      continue: true

inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ["alertname"]
```

Critical alerts go to the `oncall` receiver immediately; warnings get folded
into a slower channel. The inhibit rule suppresses warning-level noise when
the same alert is already firing critical — useful during incidents.

### 7.5 Prometheus — service discovery

Prometheus discovered every `shop-api` pod in the `shop` namespace via the
`prometheus.io/scrape=true` annotation; all targets are `UP`.

![prometheus targets](images/05_prometheus_targets.png)

### 7.6 Grafana dashboard

The provisioned dashboard (`observability/grafana/shop-api-dashboard.json`)
has four stat tiles (RPS, error %, p95 on `/work`, replica count) and four
timeseries panels (RPS per route, p50/p95/p99 latency, CPU per pod, in-flight
requests). The screenshot is taken mid-load run — RPS, p95, CPU and replica
count all move together; the autoscaler kicks in once CPU breaches 80 %.

![grafana dashboard](images/07_grafana_dashboard.png)

### 7.7 Alerts firing

`ShopApiHighErrorRate` evaluates against the recording rule
`shop_api:error_rate5m`. Prometheus shows the alert moving into the `FIRING`
state once the 5xx ratio crosses 5 % for 2 minutes.

![prometheus alert](images/06_prometheus_alert.png)

Alertmanager then receives, deduplicates and routes the alert; the screenshot
below shows the active alert in the Alertmanager UI.

![alertmanager firing](images/04_alert_firing.png)

---

## 8. Step 4 — SRE Operations (SLOs, scaling, load testing)

### 8.1 SLIs and SLOs

| SLI | Definition (PromQL) | SLO target | Error budget |
|---|---|---|---|
| Availability | `1 - shop_api:error_rate5m` | **99.5 %** monthly | 3h 39m / 30d |
| Latency (`/work`, p95) | `shop_api:latency_p95_5m{route="/work"}` | **< 800 ms** p95 | n/a (latency SLO is "fraction of good minutes") |
| Saturation | `sum(rate(container_cpu_usage_seconds_total{pod=~"shop-api-.*"}[1m])) / count(...)` | **< 80 %** average | budget triggers HPA, not paging |

Notes:
- The 5xx alert threshold (`> 5 %` for 2 min) is intentionally tighter than
  the SLO so we get paged on a *burn*, not after the budget is already gone.
- p95 latency on `/work` is the customer-facing signal; the HPA still acts on
  CPU because CPU leads latency by ~30 s on this workload.

### 8.2 Auto-scaling — `k8s/10-app-deployment.yaml` (HPA)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: shop-api, namespace: shop }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: shop-api }
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 80 }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies: [{ type: Pods, value: 4, periodSeconds: 15 }]
    scaleDown:
      stabilizationWindowSeconds: 60
      policies: [{ type: Percent, value: 50, periodSeconds: 60 }]
```

`minReplicas: 2` (not 1) so the service can survive a single pod failure
without a brief unavailability gap during scale-out. Scale-up is aggressive
(+4 pods every 15 s, no stabilisation) because the customer feels every
second of latency; scale-down is patient (60 s window, 50 % step) to avoid
flapping.

### 8.3 Load test — `load/locustfile.py`

```python
from locust import HttpUser, task, between

class ShopApiUser(HttpUser):
    wait_time = between(0.1, 0.4)

    @task(8)
    def hot_work(self):
        self.client.get("/work?iters=120000", name="/work")

    @task(2)
    def index(self):
        self.client.get("/", name="/")

    @task(1)
    def error_path(self):
        self.client.get("/error", name="/error", catch_response=True)
```

The 8:2:1 mix is deliberately CPU-heavy — `/work` dominates so the HPA
actually has to act, `/error` is included so the availability SLO and the
critical alert get exercised end-to-end in the same run.

### 8.4 Workflow

```bash
# Terminal 1 — port-forward the service
kubectl -n shop port-forward svc/shop-api 8888:5000

# Terminal 2 — run the load
cd load && pip install -r requirements.txt
locust -f locustfile.py --headless \
       -u 60 -r 15 --run-time 4m \
       -H http://localhost:8888 --csv /tmp/locust

# Terminal 3 — watch the autoscaler react
watch -n 2 'kubectl -n shop get hpa,deploy,pod'
```

### 8.5 Results

**Baseline** — 2 replicas, CPU ~ 1 %, HPA holding at min.

![k8s baseline](images/01_k8s_baseline.png)

**Under load** — Locust ramped to 60 users; CPU climbed past 250 % of
request, HPA fired several scale-up events back-to-back, replicas hit the
ceiling of 8 within ~45 s.

![hpa scaled](images/02_hpa_scaled.png)

**Locust summary** — aggregate throughput, p95 latency, 5xx ratio. The
critical 5xx alert fires roughly 2 minutes into the run.

![locust summary](images/03_locust_summary.png)

### 8.6 What the screenshots prove

| State | Replicas | CPU vs 80 % target | Notes |
|---|---|---|---|
| Idle | 2 | 1 % | At HPA floor |
| 30 s into load | 4 | 192 % | First scale-up event |
| 1 min into load | 8 | 145 % | Ceiling reached |
| Equilibrium | 8 | 78 % | Below target, holding |
| 60 s after load stops | 4 | 1 % | First step-down |
| Back to idle | 2 | 1 % | Floor restored |

The platform reconciled itself end-to-end: the autoscaler did the lifting,
the alerts notified, the dashboard told the story.

---

## 9. PRR readiness checklist

| Area | Item | State |
|---|---|---|
| Build | Reproducible image build, pinned base image | OK |
| Build | Non-root container, read-only fs not yet enforced | partial |
| Runtime | `readinessProbe` + `livenessProbe` configured | OK |
| Runtime | `resources.requests` + `limits` set | OK |
| Runtime | `minReplicas >= 2` for high availability | OK |
| Observability | RED metrics exposed at `/metrics` | OK |
| Observability | Provisioned Grafana dashboard | OK |
| Observability | Alert rules tied to SLOs | OK |
| Observability | Alertmanager routing + inhibition | OK |
| Scaling | HPA with sensible scale-up/scale-down behaviour | OK |
| Scaling | Load test validating autoscaling | OK |
| Delivery | Build → push → deploy fully automated | OK |
| Delivery | Image tagged by SHA (immutable) | OK |
| IaC | Cluster reproducible from `terraform apply` | OK |
| Operations | SLIs + SLOs written and agreed | OK |
| Operations | Runbook for top alerts | TODO (next iteration) |

## 10. ROI and closing notes

| Capability | Manual baseline | With this stack | Saving / month |
|---|---|---|---|
| Capacity reaction during traffic spikes | 4 pages × 1 h MTTR | HPA reacts in ~30 s | ~$640 (SRE time) + avoided customer impact |
| Deploy a new build | manual `docker build && kubectl apply` (~10 min, error-prone) | `git push` (~3 min, deterministic) | ~$320 (eng time) + faster rollback |
| Add a new SLO panel | edit dashboard live in Grafana (lost on restart) | edit JSON in repo, `terraform apply` | reproducibility, code review |

The technical wins are smaller than the operational ones. Once the build,
deploy and scale loops are automated, an SRE can run *more services per
engineer* — that is the only way the operation scales sub-linearly with the
size of the platform. The PRR exists to make sure each new service starts
the journey with those loops already in place, instead of bolted on after
the first incident.
