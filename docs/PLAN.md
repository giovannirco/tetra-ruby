# Plan: from a local stack to a production-shaped deployment

This repo already runs locally: the service, tests with coverage, a container image, and a Compose stack with Prometheus (alert rules loaded) and Grafana (dashboard provisioned). This page plans the rest, in the order it should land. Each step is small enough to review on its own.

## 1. Kubernetes manifests (Helm chart)

One chart in `deploy/helm/tetra`, two values profiles:

| Profile | Exposure | Use |
|---|---|---|
| `values.yaml` (default) | ClusterIP Service only: reachable only from inside the cluster | The evaluator path: `helm install`, test from a pod, `helm uninstall` |
| `values-showcase.yaml` | adds a Gateway API `HTTPRoute` (or an Ingress) for the UI | A public demo |

What the chart contains:

- **Deployment** with 2 replicas, `containerPort: 8000`, and probes: liveness `/healthz`, readiness `/readyz`, plus a startup probe so a slow first start isn't killed.
- **Graceful shutdown:** `DRAIN_DELAY_SECONDS=5` and `terminationGracePeriodSeconds: 20`. The app fails readiness, keeps serving while endpoints converge, then drains, so a rollout drops no requests.
- **Security context** following Pod Security "restricted": `runAsNonRoot`, read-only root filesystem, every capability dropped, `seccompProfile: RuntimeDefault`, and `automountServiceAccountToken: false`. The image is distroless and nonroot already.
- **Resources:** requests of 10m CPU and 32Mi memory, a 128Mi memory limit, and no CPU limit (it throttles latency with no real benefit here).
- **Availability:** a PodDisruptionBudget (`minAvailable: 1`), topology spread across nodes, and an optional HPA on CPU.
- **NetworkPolicy** (optional, off by default): ingress on 8000 only from labelled namespaces plus the monitoring namespace. It only enforces on a CNI that supports it (Cilium, Calico), so the deploy must not depend on it.
- **Image** set as `image.repository` + `image.tag`, so "change the API and redeploy" is `make image push` followed by `helm upgrade --set image.tag=<new>`. A `kind load docker-image` path covers clusters without a registry.
- **Docs:** deploy, test from inside the cluster (`kubectl run curl --rm -it --image=curlimages/curl -- sh /scripts/smoke.sh http://tetra:8000` with the script mounted from a ConfigMap, or `kubectl port-forward`), upgrade, remove.

## 2. Observability on the cluster

Metrics, logs and the dashboard are already shaped for this; the cluster side is wiring:

- **Metrics:** a `ServiceMonitor` (Prometheus Operator) scraping `/metrics` every 15s, behind a chart toggle. Plain Prometheus without the operator can use pod annotations.
- **Alerts:** `observability/prometheus/rules.yml` becomes a `PrometheusRule`. SLOs: 99.9% availability on `/api/*` (5xx only; 4xx are the caller's fault) and p99 under 50 ms. The availability alert is a fast-burn multiwindow alert; a slow-burn 6h/3d pair follows.
- **Dashboard:** `observability/grafana/dashboards/tetra.json` ships as a ConfigMap labelled for the Grafana sidecar, so it appears without clicking through the UI.
- **Logs:** JSON on stdout. Alloy (or Promtail) tails the pods into Loki and parses `request_id`, `route` and `status` as fields; a Grafana data link goes from a slow request in the dashboard to its log line.
- **Traces (next code change):** OpenTelemetry. `opentelemetry-instrumentation-rack` and `-sinatra` wrap the app, spans export over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set and stay off otherwise, `traceparent` propagates, and `trace_id` goes into the log line. Backend: Tempo, with exemplars on the latency histogram linking a p99 spike to a trace.
- **Synthetic check:** a Blackbox exporter probe (or a CronJob running `smoke.sh`) against the in-cluster Service, alerting when the contract breaks.

## 3. CI/CD

Already in `.github/workflows/ci.yml`: lint, unit tests with coverage, the contract test against the built container, and a multi-arch image (amd64 and arm64) pushed to GHCR on `main` and on tags.

Next:

- Trivy scan of the image that fails on critical CVEs, an SBOM (Syft), and a cosign keyless signature.
- `helm lint` + `kubeconform` on the chart, and a `kind` job that installs the chart and runs `smoke.sh` from inside the cluster, which is exactly the evaluator's path, run on every PR.
- GitOps: an Argo CD `Application` pointing at the chart with the showcase values. Argo CD Image Updater (or a bot PR) moves the tag; rollback is a git revert.
- Release: tags drive semver image tags; `/version` and the `tetra_build_info` metric show which build a pod runs, so a rollout is visible on the dashboard.

## 4. Integrations worth adding

- **Live events across replicas:** each pod's `/events` covers only that pod. A small bus (Redis pub/sub, or NATS) fans events out to every replica. It is optional: the broker interface stays the same and the stream falls back to local-only.
- **Load and resilience:** a k6 script (steady load, then spike) with thresholds tied to the SLOs, run in CI against kind; a game day that kills pods during load and confirms that readiness and draining keep 5xx at zero.
- **Rate limiting at the edge:** a per-client limit at the gateway for the public profile, not in the app.
- **Error tracking:** Sentry-compatible reporting of 5xx with `request_id`, behind an env var.

## 5. Out of scope on purpose

No database, no auth and no caching: the API is pure computation, and adding state would make the deploy harder to reason about without exercising anything the task asks for.
