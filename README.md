# sre-final

SRE Capstone — Production Readiness Review for `shop-api`.

**Team:** Alexey, Alihan, Iskander, Rauan

See [report.md](report.md) or open [report.html](report.html).

## Layout

- `app/` — Go service (instrumented with Prometheus) and Dockerfile
- `terraform/` — IaC (namespaces, ConfigMaps, manifests)
- `k8s/` — Deployment, Service, HPA, Prometheus, Grafana, Alertmanager manifests
- `observability/` — Prometheus config + rules, Grafana dashboard, Alertmanager config
- `load/` — Locust load test
- `.github/workflows/` — CI/CD pipeline (build → push to GHCR → deploy)
- `images/` — screenshots referenced from the report
- `render_terminal.py` — helper to render terminal text into PNGs for the report
