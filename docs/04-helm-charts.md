# Helm Charts — Validation, Design, and Reference

Covers both `charts/observability-gke/` and `charts/observability-eks/`: how they were validated
(Phase 16), why they're built the way they are (Phase 14-15's design decisions), and how to
install each against a real cluster. The two charts are structural siblings — same 4 pinned
subchart dependencies, same namespace-collapse design, same dashboard/alert-rule content — only
the cloud-specific values (`storageClassName`, Ingress annotations, identity-federation
annotations, object-storage overlay) differ. Sections below cover both together except where
noted.

## 1. Validation (Phase 16)

Neither chart was deployed to a real GKE or EKS cluster — this project has neither. Validation
instead used three layers, from generic to cluster-specific:

### `helm lint`

```
$ helm lint charts/observability-gke
==> Linting charts/observability-gke
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed

$ helm lint charts/observability-eks
==> Linting charts/observability-eks
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed
```

Both clean — the only note is an optional `icon` field neither chart sets, not an error.

### `helm template` + `kubeconform`

`kubeconform` wasn't present in this environment; downloaded the released binary directly
(v0.8.0) rather than skip this layer, since the plan treats it as "if available" but a real
schema-validation pass is worth the one-time download. Ran against the full rendered output of
both charts, with and without their respective object-storage overlay, using the
[CRDs-catalog](https://github.com/datreeio/CRDs-catalog) schema source to cover
prometheus-operator's custom resources (`PrometheusRule`, `ServiceMonitor`, `Prometheus`,
`Alertmanager`) alongside the built-in Kubernetes schema set:

```
$ helm template observability charts/observability-gke -n observability | kubeconform -summary ...
Summary: 130 resources found in 1 file - Valid: 130, Invalid: 0, Errors: 0, Skipped: 0

$ helm template observability charts/observability-eks -n observability | kubeconform -summary ...
Summary: 130 resources found in 1 file - Valid: 130, Invalid: 0, Errors: 0, Skipped: 0

$ helm template observability charts/observability-gke -n observability -f values-gcs-backend.yaml | kubeconform -summary ...
Summary: 130 resources found in 1 file - Valid: 130, Invalid: 0, Errors: 0, Skipped: 0

$ helm template observability charts/observability-eks -n observability -f values-s3-backend.yaml | kubeconform -summary ...
Summary: 130 resources found in 1 file - Valid: 130, Invalid: 0, Errors: 0, Skipped: 0
```

All four render variants: 130/130 resources schema-valid, zero errors, zero skipped (meaning the
CRD schemas were actually found and checked, not silently bypassed).

### Minikube smoke-test (real API server, not just schema validation)

The plan calls for a "smoke-test render against Minikube context with cloud-specific values
overridden to Minikube-compatible values, confirming templates are parameterized correctly (not
hardcoded to one cloud)." Went one step further than a plain render: `helm install --dry-run=server`
against the actual Minikube API server, which validates against the *real, currently-installed*
CRD definitions (not a generic catalog) and runs Kubernetes' own admission-adjacent checks —
stronger than `helm template` alone.

Built a temporary values overlay (not committed — this is a validation exercise, not a chart
deliverable) swapping every `storageClassName`/`storageClass` field from `premium-rwo`/`gp3` to
Minikube's real `standard` class:

```
$ helm install gke-smoketest charts/observability-gke -n helm-smoketest \
    -f values-minikube-smoketest.yaml --dry-run=server
[... full manifest render, no errors ...]

$ helm install eks-smoketest charts/observability-eks -n helm-smoketest \
    -f values-minikube-smoketest.yaml --dry-run=server
[... full manifest render, no errors ...]
```

Both passed. Getting there required two real fixes, not zero:

1. **First attempt failed** with a `ClusterRole ... exists and cannot be imported into the
   current release` error — because `kube-prometheus-stack.fullnameOverride` (and Loki's,
   Tempo's) are fixed to predictable names in both charts' `values.yaml`, and this Minikube
   cluster already runs the *real* Phase 5-7 deployment under those exact names. Cluster-scoped
   resources (ClusterRoles) collided. Not a chart bug — correct Kubernetes behavior when two
   Helm releases claim the same cluster-scoped resource name — but it required overriding
   `fullnameOverride` for the smoke-test release specifically, which is itself confirmation that
   these values genuinely are overridable, not hardcoded.

2. **A real, more serious bug found via this same smoke test**: this chart's own templates
   (`dashboards-configmap.yaml`, `alert-rules.yaml`, `NOTES.txt`) used a separate `.Values.namespace`
   value for their `metadata.namespace`, while every subchart (kube-prometheus-stack, Loki,
   Tempo, otel-collector) implicitly uses `.Release.Namespace`. Running
   `helm install -n helm-smoketest` without also setting `.Values.namespace` reproduced the split
   silently — the NOTES.txt output printed `kubectl port-forward -n observability ...` while
   the release had actually gone into `helm-smoketest`. Left uncorrected, this would have meant
   `helm install myrelease . -n my-ns` (any namespace other than the values.yaml default) would
   split the deployment: Prometheus/Grafana in `my-ns`, this chart's own dashboards/alerts
   silently left in `observability`. **Fixed** in both charts: removed the separate
   `namespace:` value entirely, switched every template to `.Release.Namespace` — confirmed by
   re-rendering into a third, arbitrary namespace (`my-custom-ns`) and checking all three of this
   chart's own resources landed there correctly.

This is exactly the kind of thing `helm template` alone couldn't have caught (rendering with a
fixed `-n` flag every time would never expose the mismatch) — the value of testing against a
real API server, with real existing state to collide against, over a purely static render.

## 2. Design decisions

Full reasoning lives in each chart's own `README.md` — summarized here since both charts share
it:

- **Subchart dependencies, not templated manifests**, for the four third-party components
  (`kube-prometheus-stack`, `loki`, `tempo`, `opentelemetry-collector`) — reuses upstream charts
  directly rather than re-implementing their templates, with values ported from the validated
  Minikube configuration.
- **Everything in one namespace**, collapsed from the Minikube implementation's 4-namespace
  multi-tenancy split — a real constraint (the `grafana/tempo` and `grafana/promtail` charts
  have no `namespaceOverride`), not a style choice. See §1's namespace bug above for why this
  matters more than it might first appear.
- **Promtail is a companion install, not a subchart dependency** — same `namespaceOverride`
  constraint, plus a genuine `hostPath` requirement that belongs in `kube-system` regardless.
- **RBAC/NetworkPolicy/PSS hardening is deliberately not bundled** — a platform-team concern
  applied around the chart, not packaged into it.
- **The bundled dashboard and SLO alert rule are not ports of Phase 9's sample-app-specific
  content** — that content depends on a workload (`observability-sample-app`) neither chart
  deploys. Instead: a generic `platform-overview.json` dashboard, and a disabled-by-default,
  parameterized SLO alert-rule *pattern* the operator points at their own app.
- **Object storage (GCS/S3) ships as an opt-in overlay file**, not a values toggle inside a
  single `values.yaml` — Helm values files are static data, not templated, so a real "if enabled,
  change these 12 fields across two subcharts" toggle isn't expressible within `values.yaml`
  itself; a separate overlay applied via a second `-f` flag is the idiomatic Helm pattern for
  this.

## 3. Values reference

Both charts organize `values.yaml` by subchart key (`kube-prometheus-stack:`, `loki:`, `tempo:`,
`otel-collector:`), plus this chart's own `dashboards:` and `alertRules:` keys. Every
cloud-specific value is commented in place. Quick-reference of what differs between the two:

| Value | `observability-gke` | `observability-eks` |
|---|---|---|
| PVC `storageClassName` (×5: Prometheus, Alertmanager, Grafana, Loki, Tempo) | `premium-rwo` | `gp3` |
| Grafana `ingress.ingressClassName` | `gce` | `alb` |
| Grafana `ingress.annotations` | GKE-managed-cert placeholder | `alb.ingress.kubernetes.io/*` |
| `loki`/`tempo` `serviceAccount.annotations` key | `iam.gke.io/gcp-service-account` | `eks.amazonaws.com/role-arn` |
| Object storage overlay | `values-gcs-backend.yaml` | `values-s3-backend.yaml` |

## 4. Install instructions

See each chart's own `README.md` for the full prerequisites and step-by-step:
[`charts/observability-gke/README.md`](../charts/observability-gke/README.md),
[`charts/observability-eks/README.md`](../charts/observability-eks/README.md). Both follow the
same shape:

```bash
cd charts/observability-<gke|eks>
helm dependency update
helm install observability . -n observability --create-namespace
# optional: -f values-<gcs|s3>-backend.yaml for object storage
helm install promtail grafana/promtail --version 6.17.1 -n kube-system -f values-promtail.yaml
```
