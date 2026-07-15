# observability-gke

A GKE-native Helm chart packaging the observability stack validated on Minikube in
[Kubernetes-grafana-prometheus](https://github.com/Siddharthasanapala/observability-monitoring-prom-graf-k8s):
Prometheus (HA, 2 replicas), Grafana, Alertmanager (HA, 3 replicas), Loki, Tempo, an OTel
Collector, plus dashboards and alert rules as code. See
[`docs/02-gke-documentation.md`](../../docs/02-gke-documentation.md) in the parent repo for the
full Minikube→GKE translation reasoning this chart's defaults are built from.

## Prerequisites

- A GKE **Standard** cluster (not Autopilot — see "Standard vs Autopilot" below), VPC-native,
  Workload Identity enabled:
  ```bash
  gcloud container clusters create observability-platform \
    --region=<region> --enable-ip-alias --release-channel=stable \
    --num-nodes=3 --machine-type=e2-standard-4 \
    --workload-pool=<project-id>.svc.id.goog
  ```
- `kubectl`, `helm` (v3.14+, for OCI/dependency support), pointed at that cluster.
- The `premium-rwo` StorageClass (GKE ships this by default on modern clusters; confirm with
  `kubectl get storageclass`).

## Install

```bash
cd charts/observability-gke
helm dependency update
helm install observability . -n observability --create-namespace
```

Grafana's admin password and access instructions print in the post-install `NOTES.txt`. No
Ingress is configured by default — see "Exposing Grafana" below.

### Installing Promtail

Promtail is **not** a subchart dependency of this chart — the `grafana/promtail` chart has no
`namespaceOverride`, and it needs `hostPath` mounts that put it in `kube-system` regardless of
where everything else lives (see "Design decisions" below). Install it separately:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install promtail grafana/promtail --version 6.17.1 \
  -n kube-system \
  -f values-promtail.yaml
```

### Enabling the GCS storage backend

Loki and Tempo default to PVC-backed (`premium-rwo`) storage, matching the validated Minikube
design. For the enterprise-scale path (see
[`docs/02-gke-documentation.md`](../../docs/02-gke-documentation.md) §5), layer
`values-gcs-backend.yaml` on top — read that file's header comment first, it lists the GCS
buckets and Workload Identity bindings you need to create *before* installing with it.

### Exposing Grafana externally

Set `kube-prometheus-stack.grafana.ingress.enabled: true` and fill in `hosts`/a
`GKE-managed certificate` — disabled by default because a fresh install has no hostname or TLS
cert ready yet. See the `ingress:` block in `values.yaml` for the GCE-native annotations already
staged there.

## Standard vs Autopilot

This chart is built for **GKE Standard**. Two of its components — node-exporter (part of the
`kube-prometheus-stack` subchart, via `prometheus-node-exporter.namespaceOverride: kube-system`)
and Promtail (the companion install above) — need `hostNetwork`/`hostPID`/`hostPath`, which
**GKE Autopilot does not allow**. If you're targeting Autopilot:
- Set `kube-prometheus-stack.prometheus-node-exporter.enabled: false` and use **Google Cloud
  Managed Service for Prometheus (GMP)** for node-level metrics instead.
- Skip the Promtail install and use **Cloud Logging's built-in log router** (every Autopilot
  cluster ships this automatically) instead of self-managed log shipping.

Full reasoning: [`docs/02-gke-documentation.md`](../../docs/02-gke-documentation.md) §1.

## Design decisions

**Everything in one namespace, unlike the Minikube reference implementation.** The Minikube
implementation ([`docs/01-minikube-implementation.md`](../../docs/01-minikube-implementation.md)
§Phase 3) splits `observability`/`logging`/`tracing`/`demo-app` for multi-tenancy demonstration
purposes. This chart collapses `kube-prometheus-stack`/`loki`/`tempo`/`otel-collector` into one
namespace (`observability` by default) because it's a *real constraint*, not a style choice:
checked each subchart's own `values.yaml` before deciding — `grafana/loki` and
`open-telemetry/opentelemetry-collector` both expose a top-level `namespaceOverride` (which could
have preserved the split), but **`grafana/tempo` has none at all** — it always deploys into
`.Release.Namespace`. Since Tempo can't be moved out, a partial split (Loki/OTel-collector
elsewhere, Tempo stuck in the release namespace) would be more confusing than useful, so
everything shares one namespace. Node-exporter (via its own subchart's `namespaceOverride`) and
Promtail (separate release, no `namespaceOverride` available at all) remain split out to
`kube-system`, since that one is a hard host-access requirement, not a preference.

**RBAC / NetworkPolicy / Pod Security Standard hardening is not bundled.** The Minikube reference
implementation's Phase 3-4 multi-tenancy and security baseline
([`docs/01-minikube-implementation.md`](../../docs/01-minikube-implementation.md)) is real,
validated, enterprise-shaped design — but it's a platform/security-team concern applied *around*
an observability stack, not something an observability chart should assume or dictate for every
consumer. Apply your own organization's namespace policy baseline around this chart's namespace.

**The bundled dashboard is not a port of the Minikube implementation's `sample-app-overview.json`.**
That dashboard queries metrics from Phase 8's `observability-sample-app` — a workload this chart
doesn't deploy (out of scope; see the plan's own component list for this chart:
kube-prometheus-stack, Loki, Tempo, dashboards, alert rules — not the sample app). Shipping a
dashboard that queries metrics that will never exist would be actively misleading. Instead, this
chart ships `dashboards/platform-overview.json`, a small dashboard for the platform's own health
(target up/down counts, firing alerts, Alertmanager cluster status, Prometheus TSDB size) — useful
regardless of what workloads get added later.

**The SLO alert rule is a disabled-by-default, parameterized example**, not a working alert out
of the box, for the same reason — `alertRules.slo.enabled: false`, with `jobName` needing to
point at a real Prometheus scrape job before it means anything. The pattern itself (a recording
rule computing a 5xx error ratio, feeding two burn-rate alerts) is the exact one validated in
[`docs/01-minikube-implementation.md`](../../docs/01-minikube-implementation.md) §Phase 9,
against the sample app's own metrics — copy `templates/alert-rules.yaml`'s `slo-example` block
and adjust the `expr` if your app's metric names differ from
`http_server_request_duration_seconds_count`/`http_response_status_code`
(the OpenTelemetry ASP.NET Core convention the sample app uses).

**`node-health` and `pod-crashloops` alert rules are generic and enabled by default** — they
depend only on `node_exporter`/`kube-state-metrics` metrics, which this chart always deploys, so
unlike the SLO example there's no reason to ship them disabled.

## What this chart does not do

- Does not create GCP infrastructure (the cluster itself, GCS buckets, IAM service accounts,
  Workload Identity bindings, DNS records, managed certificates) — all prerequisites, not chart
  responsibilities.
- Does not deploy a workload to observe (that's `observability-sample-app`, a separate repo — see
  the parent project's Phase 8).
- Does not apply RBAC/NetworkPolicy/PSS hardening (see "Design decisions" above).
- Does not install Promtail as part of `helm install` (see "Installing Promtail" above).

## Values reference

See `values.yaml` for the full set, organized by subchart (`kube-prometheus-stack:`, `loki:`,
`tempo:`, `otel-collector:`) plus this chart's own `namespace`, `dashboards`, and `alertRules`
keys. Every GKE-specific override (`storageClassName: premium-rwo`, `serviceAccount.annotations`
for Workload Identity, the Grafana `ingress` block) is commented in place explaining why it
differs from the Minikube values it was ported from.
