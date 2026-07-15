# Minikube Implementation — Hands-On Record

The precise record of what was built, in what order, with exact commands and file references.
This is the **pin** — Phases 12–13 (GKE/EKS documentation) reference specific sections of this
document by name when explaining what each cloud-native equivalent replaces. See
`00-architecture.md` first for the why; this document is the how, phase by phase, including the
real bugs found and fixed along the way (deliberately not sanitized — the bugs and their fixes
are as much the "hands-on record" as the manifests are).

**Environment used throughout:** Windows 11, Docker Desktop, Minikube v1.38.1, kubectl v1.35.3,
Helm v4.1.4, ArgoCD CLI v3.4.5, .NET SDK 10.0.301.

---

## Phase 1 — Minikube Cluster Provisioning

**Script:** [`scripts/01-setup-minikube.sh`](../scripts/01-setup-minikube.sh)

```bash
minikube start -p minikube --cpus=4 --memory=8192 \
  --kubernetes-version=v1.35.1 --driver=docker --cni=calico \
  --addons=metrics-server --addons=storage-provisioner \
  --addons=default-storageclass --addons=ingress
```

- **4 CPU / 8192MB**, not Minikube defaults — sized like a real node pool, not a laptop demo.
- **Kubernetes version pinned** to `v1.35.1` (resolved from `stable` at time of writing, then
  hardcoded) rather than left floating.
- **`--cni=calico`**, added retroactively during Phase 4: Minikube's default `bridge` CNI does
  not enforce `NetworkPolicy` at all. Proved this with a live test — traffic crossed a
  `default-deny-all` policy that should have blocked it, but didn't, until Calico was enabled.
  This is the single most important early-phase finding: without it, every NetworkPolicy in this
  repo would be silently inert.
- **Addons**: `metrics-server` (resource visibility), `storage-provisioner` +
  `default-storageclass` (dynamic PVC provisioning — the stand-in for GCE PD/EBS), `ingress`
  (nginx controller, stand-in for GCE Ingress/AWS ALB).
- **Validated**: dynamic PVC provisioning proven end-to-end (create → bind → delete a test PVC),
  not just "addon says enabled."

## Phase 2 — GitOps Foundation: ArgoCD Bootstrap

**Script:** [`scripts/02-bootstrap-argocd.sh`](../scripts/02-bootstrap-argocd.sh) ·
**Manifests:** [`bootstrap/argocd-install/`](../bootstrap/argocd-install/),
[`bootstrap/root-app.yaml`](../bootstrap/root-app.yaml)

1. ArgoCD v3.4.5 (pinned to match the CLI) vendored into
   `bootstrap/argocd-install/install.yaml` — not applied from a floating URL — and installed via
   `kubectl apply --server-side`. Plain client-side apply **fails** on the `applicationsets` CRD
   (`metadata.annotations: Too long: may not be more than 262144 bytes`) — a known issue with
   ArgoCD's large generated CRDs; server-side apply is the real fix, not a workaround.
2. Root App-of-Apps Application (`bootstrap/root-app.yaml`) applied by hand — the one deliberate
   exception to "nothing hand-applied." It watches `argocd-apps/` in this repo
   (`targetRevision: siddhu`) and turns every file dropped there into a live child `Application`.
3. From this point on: **write a manifest → drop a matching Application file into
   `argocd-apps/` → commit → push.** ArgoCD does the rest.
4. Validated with a throwaway placeholder child Application before any real component landed,
   proving the two-level root→child→resource sync chain actually worked, not just that the root
   app could talk to GitHub.

## Phase 3 — Namespace Strategy & Multi-Tenancy

**Manifests:** [`manifests/namespaces/`](../manifests/namespaces/) ·
**Application:** [`argocd-apps/namespaces.yaml`](../argocd-apps/namespaces.yaml)

Four namespaces, each with its own `Namespace` + `ResourceQuota` + `LimitRange`:
`observability`, `logging`, `tracing`, `demo-app`. `argocd` and `cert-manager` deliberately stay
separate (platform infrastructure, not tenant workloads).

Initial sizing (Phase 3) assumed a ~4 CPU / 8192Mi cluster budget split across the four
namespaces, weighted toward `observability` for Phase 5's HA Prometheus/Grafana/Alertmanager.
**This sizing was wrong twice, in different ways, discovered only once real workloads landed:**

- Phase 7 found `observability`'s `limits.cpu` at exactly 3/3 with zero headroom — every future
  ArgoCD sync's PreSync hook Job (`kube-prometheus-stack-admission-create`, which runs on *every*
  sync, not just install) could never schedule, wedging the Application `OutOfSync` indefinitely
  (one hook Job was found stuck retrying for 16 hours). Fixed by raising `limits.cpu`/
  `limits.memory` with real headroom for transient hook Jobs, not just a one-time unblock.
- Phase 9 found `tracing`'s original 512Mi Tempo limit OOMKilling repeatedly under real
  alert-testing traffic — ironically caught by the very `PodCrashLooping` alert Phase 9 itself
  added. Root cause was WAL replay on restart spiking well above steady-state usage after a long
  test session's accumulated trace data. Fixed by clearing the (disposable, test-only) PVC and
  resizing both the container limit and the namespace quota ceiling with real headroom.

Both are left as **retroactive edits to the Phase 3 files**, not separate patches, so the current
state of `manifests/namespaces/*.yaml` reflects the sizing lesson directly in context, with
comments explaining why.

## Phase 4 — Security & RBAC Baseline

**Manifests:** [`manifests/rbac/`](../manifests/rbac/),
[`manifests/network-policies/`](../manifests/network-policies/),
[`manifests/security/`](../manifests/security/),
[`manifests/cert-manager/`](../manifests/cert-manager/) ·
**Applications:** `argocd-apps/{rbac,network-policies,security,cert-manager}.yaml`

**RBAC** — two personas per namespace, bound to **Groups** (not ServiceAccounts) so they wire
directly into a real IdP/OIDC group claim later without touching these manifests:
- `sre-viewer` — read-only.
- `observability-admin` — CRUD on workload resources, but **deliberately excluded** from
  `rbac.authorization.k8s.io`, `resourcequotas`, `limitranges`, `networkpolicies` — governance
  objects stay GitOps-only, not self-service for a namespace admin.

First draft wildcarded the core API group (`resources: ["*"]`), which also grants
`secrets`/`resourcequotas`/`limitranges` read/write — directly defeating the "viewer can't read
secrets" and "admin can't touch governance" intent. Fixed by enumerating resources explicitly per
`apiGroup` instead of wildcarding.

**Pod Security Standards** — `restricted` enforced via namespace labels on all four tenant
namespaces. This is what later forced node-exporter (Phase 5) and Promtail (Phase 6) out into
`kube-system` — flagged as a *known, planned* conflict in each namespace's own file comments
*before* either component was deployed, specifically so it wasn't a surprise mid-phase.

**NetworkPolicy** — default-deny-all per namespace with explicit allows, discovered/refined
almost entirely through live failures in later phases (see Phase 5's NetworkPolicy findings
below) rather than guessed upfront. The one Phase-4-native finding: Calico's egress evaluation
happens *after* kube-proxy's ClusterIP→node-IP DNAT on this cluster, so `ipBlock` rules for
node-level services (API server, node-exporter, kubelet) must target the **node's actual IP**
(`192.168.49.2` on this Minikube instance), not the ClusterIP — confirmed by testing both and
observing only the node-IP version actually succeeds. This is Minikube-specific and explicitly
flagged as needing a redesign for GKE/EKS (their control planes aren't cluster nodes at all).

**cert-manager** — v1.16-era install vendored to `manifests/cert-manager/install.yaml` (same
server-side-apply CRD-size issue as ArgoCD, same fix), plus a self-signed `ClusterIssuer`
(`manifests/security/cluster-issuer.yaml`). Exists to prove the pattern is provable on Minikube;
Phases 12–13 document the cloud-managed replacements (GCP Certificate Manager + Workload
Identity / AWS ACM + IRSA + External Secrets).

## Phase 5 — Metrics Stack (Prometheus + Grafana + Alertmanager)

**Values:** [`manifests/kube-prometheus-stack/values.yaml`](../manifests/kube-prometheus-stack/values.yaml) ·
**Application:** [`argocd-apps/kube-prometheus-stack.yaml`](../argocd-apps/kube-prometheus-stack.yaml) ·
Chart: `prometheus-community/kube-prometheus-stack@87.15.2`, multi-source (Helm chart + this
repo's values file).

Configuration: Prometheus **2 replicas**, Alertmanager **3 replicas** (odd number for real
gossip-protocol quorum — 2 gives no real HA advantage over 1), Grafana with PVC persistence, all
PVC-backed via the `standard` StorageClass from Phase 1.

Four real bugs found only by deploying for real, not by reading the chart's docs:

1. **Grafana's `initChownData` init container runs as root** (CHOWN/DAC_OVERRIDE to fix PVC
   ownership) — rejected outright by `restricted` PSS. Disabled it; redundant anyway since
   `securityContext.fsGroup` already makes the volume group-writable without root.
2. **Prometheus/Alertmanager pods generated by the Operator only set pod-level
   `securityContext`** (`runAsNonRoot`, `seccompProfile`) — the container-level
   `allowPrivilegeEscalation`/`capabilities.drop` fields `restricted` PSS also requires were
   simply absent from the chart's defaults. Patched in explicitly via each CRD's `containers:`
   override array (a documented prometheus-operator mechanism for patching generated containers
   by name).
3. **Every container defaulted to the namespace `LimitRange`'s 500m-CPU ceiling** since the chart
   sets no resource requests/limits itself — with 2 Prometheus + 3 Alertmanager replicas × 2
   containers each, this alone blew the 3-CPU quota and blocked scheduling. Fixed with explicit,
   right-sized `resources:` per component. A second pass then found the LimitRange's *minimum*
   (50m CPU / 64Mi memory) rejecting the small sidecars I'd sized *below* that floor — every
   value in the final `values.yaml` is ≥ 50m/64Mi.
4. **node-exporter needs `hostNetwork`/`hostPID`/`hostPath`**, flatly incompatible with
   `restricted` — moved to `kube-system` via `prometheus-node-exporter.namespaceOverride`, the
   fix flagged as a known conflict back in Phase 4 before this phase even started.

Also found and fixed: Prometheus couldn't reach the API server, node-exporter, or kubelet at all
(scrape targets stuck `down`) — the NetworkPolicy node-IP-vs-ClusterIP finding described in
Phase 4 was actually discovered *here*, live-debugging why scrapes were timing out, then
retroactively documented in the Phase 4 NetworkPolicy files. `kube-scheduler`/
`kube-controller-manager`/`kube-etcd` stayed permanently `down` even after the NetworkPolicy fix
— checked their actual static-pod flags and confirmed Minikube hardcodes them to bind
`127.0.0.1` only, unreachable from any pod on any network configuration. Disabled those three
ServiceMonitors rather than leave permanently-failing targets in Prometheus (`kube-proxy`, which
binds `0.0.0.0`, stayed enabled — genuinely reachable).

**Validated**: Grafana reachable, all Prometheus targets healthy (after the fixes above),
Alertmanager cluster status `ready` with all 3 peers joined via direct API query.

## Phase 6 — Logging Stack (Loki + Promtail)

**Values:** [`manifests/loki/values.yaml`](../manifests/loki/values.yaml),
[`manifests/loki/promtail-values.yaml`](../manifests/loki/promtail-values.yaml) ·
**Applications:** [`argocd-apps/loki.yaml`](../argocd-apps/loki.yaml),
[`argocd-apps/promtail.yaml`](../argocd-apps/promtail.yaml) ·
Charts: `grafana/loki@7.0.0` (SingleBinary mode), `grafana/promtail@6.17.1`.

**Loki**: `SingleBinary` deployment mode (not the chart's SimpleScalable default) — a
multi-component read/write/backend topology is unneeded complexity at this scale, and would have
repeated Phase 5's resource-sizing problem across more pods. `storage.backend: filesystem`
(already the chart default) backed by the same `standard` PVC pattern. Chart-default `gateway`,
`resultsCache`, `chunksCache`, `lokiCanary` all disabled — an nginx proxy, two memcached
deployments, and a synthetic-log DaemonSet add nothing at this scale. One install-time bug: the
chart's `read`/`write`/`backend` components default to 3 replicas *regardless* of
`deploymentMode` and the chart refuses to start if both SingleBinary and these are simultaneously
non-zero — explicitly zeroed all three.

**Promtail** deploys into **`kube-system`, not `logging`** — same hostPath-mounts-vs-`restricted`
conflict as node-exporter, flagged when `logging`'s PSS labels were written in Phase 4. Since
Promtail is a standalone chart (no `namespaceOverride` the way kube-prometheus-stack's
node-exporter subchart has one), this needed its **own** ArgoCD Application with its own
`destination.namespace`, not a second Helm source folded into `loki.yaml` — one Application =
one destination namespace. Because the chart's default Loki push URL
(`http://loki-gateway/...`) assumes the gateway component (which is disabled here), Promtail's
client URL is pointed directly at Loki's own service instead.

**NetworkPolicy**: `logging` needed a new ingress rule allowing push traffic *from* `kube-system`
(where Promtail now lives) on Loki's port 3100 — distinct from the existing Grafana-query ingress
rule, since it's a different source namespace.

**Validated**: Promtail confirmed shipping logs from every namespace in the cluster (`argocd`,
`cert-manager`, `demo-app`, `kube-system`, `logging`, `observability`, `tracing`); a real LogQL
query run **through Grafana's own datasource proxy** (not just Loki's raw API) returned live pod
logs — the datasource wiring in
[`manifests/kube-prometheus-stack/values.yaml`](../manifests/kube-prometheus-stack/values.yaml)'s
`grafana.additionalDataSources` was proven working end-to-end, not just declared.

## Phase 7 — Tracing Stack (Tempo + OpenTelemetry Collector)

**Values:** [`manifests/tempo/values.yaml`](../manifests/tempo/values.yaml),
[`manifests/tempo/otel-collector-values.yaml`](../manifests/tempo/otel-collector-values.yaml) ·
**Applications:** [`argocd-apps/tempo.yaml`](../argocd-apps/tempo.yaml),
[`argocd-apps/otel-collector.yaml`](../argocd-apps/otel-collector.yaml) ·
Charts: `grafana/tempo@1.24.4` (single-binary), `open-telemetry/opentelemetry-collector@0.165.0`.

Tempo's own defaults *already* include an OTLP receiver — apps could send traces straight to
Tempo. A dedicated OTel Collector sits in front anyway, per the plan's explicit design, so app
instrumentation depends on a vendor-neutral ingestion point rather than Tempo's endpoint
specifically. Collector config trimmed to a traces-only pipeline (`receivers: [otlp]`,
`exporters: [debug, otlp/tempo]`) — the chart's default logs/metrics pipelines are redundant with
Loki/Prometheus's own paths.

Bugs found via live install:
- **Recent `opentelemetry-collector` chart versions dropped their default image entirely**,
  failing fast with `'image.repository' must be set` rather than silently picking one. Set to the
  `contrib` distribution + matching `command.name: otelcol-contrib`, the chart's own recommended
  choice for broadest receiver/exporter support.
- **Tempo's pod-level `securityContext` is missing `seccompProfile`**, required by `restricted`
  PSS — otherwise already fully compliant out of the box, unlike Prometheus/Alertmanager in Phase
  5. Container-level `securityContext` ships as an *empty* `{}` with the restricted fields as
  commented-out examples — filled in, with one deliberate exception: the chart's own comment
  warns `readOnlyRootFilesystem: true` "fails, do not enable" (Tempo writes local trace
  blocks/WAL to disk), so that field is left unset.
- **Grafana's admin password auto-regenerates on every Helm render** — ArgoCD saw this as
  permanent drift on the Secret and would rotate the live password on every sync. Fixed with
  `ignoreDifferences` in
  [`argocd-apps/kube-prometheus-stack.yaml`](../argocd-apps/kube-prometheus-stack.yaml) on the
  Secret's `data.admin-password` and the Deployment's `checksum/secret` annotation.

**Validated**: sent a synthetic OTLP trace from a pod in `demo-app` through the Collector
(`HTTP 200`) and queried Tempo directly by trace ID — confirming both the OTLP ingest path and
Phase 4's NetworkPolicy rules (written *before* this phase existed) needed zero changes.

## Phase 8 — Demo Workload

**Repo:** [`observability-sample-app`](https://github.com/Siddharthasanapala/observability-sample-app)
(sibling repo — see its own `README.md` for the telemetry design) ·
**Manifests:** [`manifests/sample-app/`](../manifests/sample-app/) ·
**Application:** [`argocd-apps/sample-app.yaml`](../argocd-apps/sample-app.yaml)

ASP.NET Core (.NET 10) "orders" API with an in-memory (EF Core) store and a deliberately
multi-span endpoint: `GET /api/orders/{id}/enriched` fetches the order, then calls
`GET /api/pricing/{productName}` **over real HTTP** (`HttpClient`, not an in-process call) so a
single request produces a genuine 3-span trace
(`OrdersController` handler → `HttpClient` call → `PricingController` handler), proving
distributed-trace propagation rather than "a span exists."

- **Metrics**: ASP.NET Core auto-instrumentation + a custom `Meter` for business events
  (`sampleapp.orders.created`, `sampleapp.orders.enrich.duration`), exposed at `/metrics` via
  `OpenTelemetry.Exporter.Prometheus.AspNetCore` — Prometheus scrapes directly, no push gateway.
- **Traces**: OTLP export to the in-cluster OTel Collector, endpoint read from the standard
  `OTEL_EXPORTER_OTLP_ENDPOINT` env var (set by the Deployment, never hardcoded) so the same
  image works unmodified against any collector.
- **Logs**: structured JSON to stdout via Serilog, enriched with the current `TraceId`/`SpanId`
  (`Serilog.Enrichers.Span`, reads `Activity.Current`) — **deliberately not** a second OTLP log
  path; Promtail already tails every container's stdout cluster-wide, so a parallel path would be
  redundant. This is what makes trace↔log correlation possible without extra plumbing: every log
  line already carries the same `TraceId` Tempo shows for that request.

`Dockerfile`: multi-stage (SDK image only for compiling), runs as the base image's built-in
non-root `$APP_UID`. `.github/workflows/build-push.yaml` builds and pushes to
`ghcr.io/siddharthasanapala/observability-sample-app` on every push, tagged by commit SHA — the
Deployment manifest pins the exact SHA tag, not a floating branch tag. The GHCR package is
public, confirmed pullable anonymously — no `imagePullSecret` needed.

**Validated end-to-end**: generated real traffic, then — for one specific request — found the
**same trace ID** present in both Loki (structured log line, `TraceId` field) and Tempo (as the
actual 3-span trace described above), confirmed via Prometheus that
`sampleapp_orders_created_total` incremented correctly. One trace ID, one real request, present
and correlated across all three pillars.

## Phase 9 — Dashboards, Alert Rules & SLOs as Code

**Manifests:** [`manifests/dashboards/`](../manifests/dashboards/),
[`manifests/alert-rules/`](../manifests/alert-rules/) ·
**Applications:** [`argocd-apps/dashboards.yaml`](../argocd-apps/dashboards.yaml) (Kustomize
source), [`argocd-apps/alert-rules.yaml`](../argocd-apps/alert-rules.yaml) (directory source)

Dashboard JSON kept as a pure, directly-editable file
([`sample-app-overview.json`](../manifests/dashboards/sample-app-overview.json)) rather than
hand-embedded inside a YAML `data:` block — a Kustomize `configMapGenerator`
([`kustomization.yaml`](../manifests/dashboards/kustomization.yaml)) wraps it with the
`grafana_dashboard: "1"` label the sidecar watches for.

Three `PrometheusRule` groups — `node-health.yaml`, `pod-crashloops.yaml`, `sample-app-slo.yaml`
— all requiring the `release: kube-prometheus-stack` label to be picked up (confirmed against an
existing shipped rule's labels before writing these; same convention as `ServiceMonitor`). The
SLO rule is a **deliberately simplified single-window burn-rate alert**, not the full Google SRE
workbook multi-window approach — documented as such in the file.

**Validated with two real fired alerts, not simulated ones:**
- Added a `GET /api/orders/chaos/fail` endpoint to the sample app (always returns 500) purely for
  this validation, committed/pushed/rebuilt through the same CI pipeline as any other change.
  Hammered it, watched the error-rate recording rule climb to ~73%, both `SampleAppHighErrorRate`
  and `SampleAppCriticalErrorRate` alerts transition `pending`→`firing`, confirmed **active in
  Alertmanager**, and confirmed the dashboard's own panel query returns the identical value
  through Grafana's proxy. Stopped the traffic — both alerts correctly resolved to `inactive`,
  proving the full fire→resolve lifecycle, not just the fire half.
- Triggered `PodCrashLooping` via a temporary (non-destructive, same cached image) command
  override — but it fired first for a **genuinely unrelated real problem**: `tempo-0` was
  actually `OOMKilled` and crash-looping from WAL replay pressure after this session's heavy
  trace-generation testing. The alert caught a real issue, not a synthetic one. Fixed by clearing
  the disposable test-only PVC and resizing Tempo's memory limit (documented in Phase 5's
  namespace-sizing note above, applied here to `tracing`).

## Phase 10 — End-to-End Validation

**Script:** [`scripts/validate.sh`](../scripts/validate.sh)

Seven-section, 26-check gate: ArgoCD sync/health for all 14 Applications, Prometheus target
health, Loki ingestion breadth, Tempo span presence, Grafana dashboard rendering, RBAC
least-privilege behavior, NetworkPolicy structural presence. All data-plane checks run via
`kubectl exec` curl **from inside the Grafana pod** against in-cluster Service DNS rather than
external `kubectl port-forward` tunnels — port-forwards proved repeatedly flaky throughout hands-
on development (stale processes holding ports, connections dying mid-check), and exec'ing from a
pod already on the cluster network is both more robust and a more honest test of what actually
matters (in-cluster reachability, not operator-laptop reachability).

Clean run: **26/26 passed**, exit code 0. The plan's own gate condition — "do not proceed to
documentation phases until this passes" — is satisfied; this document exists because it did.

---

## Operational lessons (patterns that recurred across multiple phases)

**`selfHeal` reverts unpushed live edits, usually within seconds.** Every Application has
`automated: {prune: true, selfHeal: true}`. Any `kubectl`/`helm` edit made directly against the
live cluster — for validating a fix before pushing it — gets silently reverted back to match the
last-pushed commit, often within 3–5 seconds. Hit repeatedly: NetworkPolicy fixes, ResourceQuota
bumps, sample-app image tag updates. **Workaround used throughout**: temporarily set the specific
Application's sync policy to none (`argocd app set <name> --sync-policy none`) — and, since
`root-app-of-apps` itself manages every child `Application` object as a resource, sometimes that
needed pausing too — validate the fix, then restore `automated` sync afterward. This is normal,
correct GitOps behavior (Git is authoritative), not a bug, but it's disruptive enough during
active development that it's worth knowing about upfront.

**PVC-backed Grafana's admin password can silently desync from its own Secret.** The
`GF_SECURITY_ADMIN_PASSWORD` env var only seeds a *brand-new* SQLite database on first boot;
once persistence is enabled (Phase 5), later Secret rotations (see Phase 7's `ignoreDifferences`
fix) don't propagate to the already-existing admin account. Restarting the pod does not fix this
— the correct fix is `grafana cli admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD"` run
inside the pod, which rewrites the persisted DB without touching dashboards/datasources. Worth a
proper fix in a later phase (e.g., `admin.existingSecret` pointing at a stable, out-of-band
Secret) rather than working around it every time.

**Chart defaults are a starting point, not a guarantee of PSS compliance or correct sizing.**
Every single Helm-deployed component in this repo needed at least one live-deployment fix that no
amount of reading the chart's `values.yaml` comments would have caught — a missing
`seccompProfile`, an empty container `securityContext`, a resource default that collides with a
`LimitRange` minimum, an image reference the chart stopped shipping by default. The pattern that
worked: inspect the chart's actual rendered defaults before writing values (`helm show values`),
deploy for real, read the actual error, fix, re-verify — not assume-and-move-on.
