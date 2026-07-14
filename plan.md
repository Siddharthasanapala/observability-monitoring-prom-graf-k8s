# Plan: Enterprise Observability & Monitoring on Kubernetes
### Hands-on Minikube implementation → GKE & EKS documentation → GKE/EKS-native Helm charts

---

## 1. Objective

Build a real, working, enterprise-shaped observability stack on **Minikube** (not a toy demo), GitOps-managed end-to-end with **ArgoCD**, then:

1. Document the exact hands-on Minikube implementation (every manifest, command, decision).
2. Translate and document the same architecture as it would be implemented **natively on GKE** and **natively on EKS**, explicitly referencing back to the Minikube artifacts that each cloud-specific piece replaces or extends.
3. Ship **two production-shaped Helm charts** — `observability-gke` and `observability-eks` — that encode the final, validated design as installable, cloud-native packages.
4. Produce a final reference document that indexes every doc/manifest/chart produced, so the whole body of work is navigable as one deliverable.

## 2. Final Requirements Checklist (what "done" means)

- [ ] Minikube cluster running a full observability stack: **metrics (Prometheus/Grafana/Alertmanager) + logs (Loki/Promtail) + traces (Tempo)**.
- [ ] 100% of cluster state deployed and changed **only through ArgoCD** (App-of-Apps pattern), Git is the single source of truth, full commit history = manifest history.
- [ ] Enterprise baseline present: **namespace-based multi-tenancy, RBAC least-privilege, NetworkPolicies, HA replica counts, persistent storage**.
- [ ] A real ASP.NET Core workload (own git repo, own GHCR image) instrumented and emitting metrics/logs/traces, proving the pipeline end-to-end (not just infra running idle).
- [ ] `docs/01-minikube-implementation.md` — hands-on record of what was actually built.
- [ ] `docs/02-gke-documentation.md` — GKE-native translation, pinned to Minikube artifacts.
- [ ] `docs/03-eks-documentation.md` — EKS-native translation, pinned to Minikube artifacts.
- [ ] `charts/observability-gke/` — Helm chart, GKE-native defaults, installable on a real GKE cluster.
- [ ] `charts/observability-eks/` — Helm chart, EKS-native defaults, installable on a real EKS cluster.
- [ ] `README.md` / `docs/00-index.md` — final reference tying every doc, manifest, and chart together.

## 3. Confirmed Scope Decisions

| Decision | Choice |
|---|---|
| Telemetry pillars | Metrics + Logs + Traces (full three-pillar stack) |
| Metrics stack | `kube-prometheus-stack` (Prometheus Operator, Prometheus, Grafana, Alertmanager) |
| Logs stack | Loki + Promtail |
| Traces stack | Tempo (+ OpenTelemetry Collector for ingestion) |
| Enterprise hardening | Multi-tenancy/namespace isolation, HA + persistence, Security/RBAC |
| GitOps pattern | ArgoCD **App-of-Apps** (root Application → child Applications per component) |
| Source of truth | Local folder, `git init` here; ArgoCD points at this repo once pushed to a remote |
| Sample workload | ASP.NET Core app, instrumented with OpenTelemetry .NET SDK (metrics/logs/traces) |
| Sample app repo | **Separate** local git repo (`observability-sample-app/`), independent of this GitOps repo |
| Sample app image | Built and pushed to **GitHub Container Registry (GHCR)**, referenced by tag from the ArgoCD-managed Deployment manifest |
| Environment verified | minikube v1.38.1, kubectl v1.35.3, helm v4.1.4, argocd CLI v3.4.5, Docker 29.4.0 — all present |

## 4. Target Repository Layout

This plan spans **two git repositories**, mirroring how a real org separates the platform/GitOps repo from an application team's repo:

- `Kubernetes-grafana-prometheus/` (this repo) — all platform/observability GitOps content: ArgoCD apps, Helm values, RBAC, docs, the two final Helm charts.
- `observability-sample-app/` (new, sibling repo, e.g. `d:\observability-sample-app`) — the ASP.NET Core demo app's source code, Dockerfile, and GitHub Actions workflow to build/push the image to GHCR. Only its **Deployment manifest + image tag** are referenced from this repo (`manifests/sample-app/`) — the app's source never lives here.

This structure is the backbone of the plan — every phase below produces specific files in one of the two repos.

```
Kubernetes-grafana-prometheus/
├── plan.md                                  # this file
├── README.md                                # final index (written last, stubbed early)
├── docs/
│   ├── 00-architecture.md                   # cross-cutting architecture & decisions record
│   ├── 01-minikube-implementation.md        # hands-on record (Phase 11)
│   ├── 02-gke-documentation.md              # GKE-native translation (Phase 12)
│   ├── 03-eks-documentation.md              # EKS-native translation (Phase 13)
│   ├── 04-helm-charts.md                    # chart design/usage doc (Phase 17)
│   └── assets/                              # diagrams, screenshots
├── bootstrap/
│   ├── argocd-install/                      # ArgoCD install manifests (Phase 2)
│   └── root-app.yaml                        # App-of-Apps root Application (Phase 2)
├── argocd-apps/                             # one Application manifest per component (Phase 2+)
│   ├── kube-prometheus-stack.yaml
│   ├── loki.yaml
│   ├── tempo.yaml
│   └── sample-app.yaml
├── manifests/
│   ├── namespaces/                          # Phase 3
│   ├── rbac/                                # Phase 4
│   ├── network-policies/                    # Phase 4
│   ├── kube-prometheus-stack/values.yaml    # Phase 5
│   ├── loki/values.yaml                     # Phase 6
│   ├── tempo/values.yaml                    # Phase 7
│   ├── dashboards/                          # Phase 9
│   ├── alert-rules/                         # Phase 9
│   └── sample-app/                          # Phase 8
├── charts/
│   ├── observability-gke/                   # Helm chart #1 (Phase 14)
│   └── observability-eks/                   # Helm chart #2 (Phase 15)
└── scripts/
    ├── 01-setup-minikube.sh
    ├── 02-bootstrap-argocd.sh
    └── validate.sh
```

Sibling repo for the sample app:

```
observability-sample-app/
├── .github/workflows/build-push.yaml   # builds image, pushes to GHCR on push/tag
├── src/
│   └── SampleApp/                      # ASP.NET Core app
│       ├── Program.cs                  # OpenTelemetry SDK wiring (metrics/logs/traces)
│       ├── Controllers/                # a couple of endpoints that do real work (DB/HTTP call/queue)
│       └── SampleApp.csproj
├── Dockerfile
└── README.md
```

---

## 5. Phased Implementation Plan

Each phase = one working session. We do them **in order**; each phase's deliverables are inputs to the next. I will not start a phase until the previous one is confirmed working.

### Phase 0 — Repo & Git Foundations
**Goal:** Establish the GitOps source of truth before anything touches the cluster.
- `git init` in `d:\Kubernetes-grafana-prometheus`.
- Create the directory skeleton from Section 4 (empty `.gitkeep` placeholders where needed).
- Add `.gitignore` (kubeconfig dumps, `.terraform` if used later, OS files).
- Initial commit.
- **Note:** a remote (GitHub/GitLab) will be needed before ArgoCD can track this repo from a real GKE/EKS cluster later — can stay local for the Minikube phase since ArgoCD can also sync from a local/self-hosted git server, but for a clean GKE/EKS story we should push to a remote before Phase 2. Flag this decision point when we reach it.
- **Deliverable:** initialized repo, skeleton committed.

### Phase 1 — Minikube Cluster Provisioning (enterprise-shaped)
**Goal:** A cluster sized and configured like a real environment, not a default `minikube start`.
- Start Minikube with realistic resources (multi-CPU/memory, e.g. `--cpus=4 --memory=8192`), a recent Kubernetes version, and the `metrics-server`, `storage-provisioner`, and `ingress` addons enabled.
- Confirm default `StorageClass` supports dynamic PVC provisioning (Minikube's `standard` class) — this is the stand-in for GCE PD / EBS later.
- Document exact command(s) used in `scripts/01-setup-minikube.sh`.
- **Deliverable:** running cluster, `scripts/01-setup-minikube.sh`.
- **Validation:** `kubectl get nodes`, `kubectl get storageclass` show expected state.

### Phase 2 — GitOps Foundation: Install & Bootstrap ArgoCD
**Goal:** From this point forward, **nothing is applied with raw `kubectl apply` except ArgoCD's own bootstrap** — everything else goes through Git → ArgoCD.
- Install ArgoCD into an `argocd` namespace (`bootstrap/argocd-install/`).
- Expose/access ArgoCD UI (port-forward or minikube tunnel) and log in via `argocd` CLI.
- Create the **root App-of-Apps** Application (`bootstrap/root-app.yaml`) pointed at `argocd-apps/` in this repo.
- Each subsequent component (namespaces, RBAC, Prometheus stack, Loki, Tempo, sample app) becomes a child `Application` manifest added to `argocd-apps/`.
- **Deliverable:** `bootstrap/argocd-install/`, `bootstrap/root-app.yaml`, working ArgoCD UI, `scripts/02-bootstrap-argocd.sh`.
- **Validation:** ArgoCD UI shows the root app; syncing an empty/placeholder child app succeeds.

### Phase 3 — Namespace Strategy & Multi-Tenancy
**Goal:** Enterprise-style isolation before workloads land.
- Define namespaces: `observability` (Prometheus/Grafana/Alertmanager), `logging` (Loki/Promtail), `tracing` (Tempo), `demo-app` (sample workload), keep `argocd` separate.
- Add `ResourceQuota` + `LimitRange` per namespace (`manifests/namespaces/`).
- Register namespaces as an ArgoCD child Application (`argocd-apps/namespaces.yaml`) so they're GitOps-managed too.
- **Deliverable:** `manifests/namespaces/*.yaml`, `argocd-apps/namespaces.yaml`.
- **Validation:** `kubectl get ns`, `kubectl describe resourcequota -n <ns>`.

### Phase 4 — Security & RBAC Baseline
**Goal:** Least-privilege access and network isolation, matching what a real enterprise cluster would require before onboarding.
- RBAC: per-namespace `Role`/`RoleBinding` for a read-only "SRE viewer" and an "observability-admin" role (`manifests/rbac/`).
- `NetworkPolicy` default-deny per observability namespace, with explicit allow rules for scrape/query/ingest traffic (`manifests/network-policies/`).
- Pod Security: enforce `restricted` Pod Security Standard on observability namespaces (namespace labels).
- Note but defer to GKE/EKS docs: TLS/cert-manager and secret-management (Sealed Secrets/External Secrets) are cloud-IAM-adjacent — implement a minimal cert-manager (self-signed issuer) on Minikube so the pattern is provable, and describe the cloud-managed equivalents (GCP Certificate Manager + Workload Identity / AWS ACM + IRSA + External Secrets) in Phases 12–13.
- **Deliverable:** `manifests/rbac/`, `manifests/network-policies/`, registered as ArgoCD child apps.
- **Validation:** `kubectl auth can-i` checks confirm least-privilege; NetworkPolicy blocks cross-namespace traffic as expected.

### Phase 5 — Metrics Stack (Prometheus + Grafana + Alertmanager)
**Goal:** Deploy `kube-prometheus-stack` entirely via ArgoCD, HA + persistent.
- Author `manifests/kube-prometheus-stack/values.yaml`: Prometheus with 2 replicas + PVC-backed storage, Alertmanager with 2/3 replicas + PVC, Grafana with persistence enabled and provisioned datasources.
- Register as ArgoCD Application `argocd-apps/kube-prometheus-stack.yaml` (Helm source, this values file).
- **Deliverable:** working Prometheus, Grafana, Alertmanager in `observability` namespace, all PVC-backed.
- **Validation:** Grafana reachable, Prometheus targets healthy, Alertmanager cluster status shows all replicas joined.

### Phase 6 — Logging Stack (Loki + Promtail)
**Goal:** Cluster-wide log aggregation, GitOps-managed.
- Author `manifests/loki/values.yaml`: Loki with persistence, Promtail as DaemonSet shipping all pod logs.
- Register `argocd-apps/loki.yaml`.
- Wire Loki as a Grafana datasource (extend Phase 5's Grafana provisioning).
- **Deliverable:** logs from every namespace queryable in Grafana Explore.
- **Validation:** LogQL query in Grafana returns live pod logs.

### Phase 7 — Tracing Stack (Tempo + OpenTelemetry Collector)
**Goal:** Distributed tracing pipeline, GitOps-managed.
- Author `manifests/tempo/values.yaml`: Tempo with persistence; deploy an OpenTelemetry Collector to receive OTLP and forward to Tempo.
- Register `argocd-apps/tempo.yaml`.
- Wire Tempo as a Grafana datasource, with trace-to-logs/trace-to-metrics correlation configured.
- **Deliverable:** Tempo + OTel Collector running, Grafana datasource wired.
- **Validation:** placeholder confirmed once Phase 8's app sends real traces.

### Phase 8 — Demo Workload (proves the pipeline end-to-end)
**Goal:** A real instrumented app, not synthetic load — this is what makes the whole stack "prove" itself.

**8a. Sample app repo (`observability-sample-app/`, separate repo)**
- `dotnet new webapi` scaffold with 2–3 endpoints that do real work (e.g. an in-memory/SQLite "orders" CRUD + one endpoint that calls another endpoint, so a trace has more than one span).
- Wire `OpenTelemetry.Extensions.Hosting` SDK for:
  - **Metrics** — ASP.NET Core request metrics + custom `Meter`/counter for business events, exposed via Prometheus exporter (`/metrics`).
  - **Traces** — ASP.NET Core + HttpClient auto-instrumentation, OTLP exporter pointed at the cluster's OTel Collector (Phase 7).
  - **Logs** — structured logging (`ILogger`) with OTLP log exporter, or stdout JSON scraped by Promtail — pick one and document why.
- `Dockerfile` (multi-stage build, non-root user — ties back to Phase 4's security baseline).
- `.github/workflows/build-push.yaml`: on push to `main`/tag, build image, push to `ghcr.io/<owner>/observability-sample-app:<tag>`.
- Init this repo, commit, push to GitHub, confirm the Actions workflow produces a pullable GHCR image.

**8b. Deploy into the cluster (this repo, GitOps-managed)**
- `manifests/sample-app/`: Deployment referencing the GHCR image tag, Service, ServiceMonitor (for Prometheus scraping), non-root/least-privilege PodSecurityContext.
- Register `argocd-apps/sample-app.yaml`, deployed to `demo-app` namespace (Phase 3).
- If GHCR image is private, create the `imagePullSecret` (document as a manually-provisioned secret, or note the cloud-native replacement — Workload Identity/IRSA-federated pulls — in Phases 12–13).

- **Deliverable:** `observability-sample-app/` repo (source, Dockerfile, CI) + `manifests/sample-app/` + `argocd-apps/sample-app.yaml` in this repo.
- **Validation:** app's custom metrics visible in Prometheus, its logs in Loki, its request traces in Tempo — same request correlated across all three (trace ID visible in logs, linked from Tempo to Loki in Grafana).

### Phase 9 — Dashboards, Alert Rules & SLOs as Code
**Goal:** Observability content itself is version-controlled, not click-ops in the Grafana UI.
- Grafana dashboards as JSON in `manifests/dashboards/`, loaded via ConfigMap sidecar provisioning.
- `PrometheusRule` alert rules in `manifests/alert-rules/` (node health, pod crashloops, HTTP error-rate SLO burn alerts for the demo app).
- **Deliverable:** dashboards auto-appear in Grafana on sync; alerts visible in Alertmanager.
- **Validation:** trigger a deliberate failure in the demo app, confirm alert fires and dashboard reflects it.

### Phase 10 — End-to-End Validation on Minikube
**Goal:** Formal sign-off that the Minikube implementation is complete before documentation starts.
- Run `scripts/validate.sh`: checks ArgoCD sync status of every Application is `Synced`/`Healthy`, Prometheus targets up, Loki ingesting, Tempo receiving spans, Grafana dashboards rendering, RBAC/NetworkPolicy checks pass.
- **Deliverable:** `scripts/validate.sh`, a clean validation run.
- **Gate:** do not proceed to documentation phases until this passes.

### Phase 11 — Document the Minikube Implementation
**Goal:** `docs/01-minikube-implementation.md` — a precise, hands-on record: what was installed, exact commands, exact file paths (linking to the actual manifests in this repo), architecture diagram, and the reasoning behind each enterprise-hardening decision (Phases 3–4). This document is the **pin** that Phases 12–13 continually reference back to ("this replaces `manifests/kube-prometheus-stack/values.yaml` storage section with GCE PD...").
- **Deliverable:** `docs/01-minikube-implementation.md`, `docs/00-architecture.md`.

### Phase 12 — GKE-Native Documentation
**Goal:** `docs/02-gke-documentation.md` — translate every Minikube component to its GKE-native equivalent, explicitly citing the Minikube manifest/doc section it replaces.
- Cluster: GKE Standard vs Autopilot tradeoffs for running Prometheus (Autopilot's restrictions on DaemonSets/hostPath affect Promtail/Node Exporter — call this out explicitly).
- Storage: `standard-rwo`/`premium-rwo` GCE PD StorageClasses replacing Minikube's `standard` class.
- Identity: Workload Identity for any component needing GCP API access (e.g. GCS-backed Loki/Tempo storage).
- Networking: GKE Ingress (GCE controller) or Gateway API, Cloud DNS, VPC-native (alias IP) clusters, NetworkPolicy via Dataplane V2/Calico.
- Long-term storage option: GCS buckets as Loki/Tempo object storage backend (vs. local PVC on Minikube) — note as the enterprise-scale upgrade path.
- Managed alternative note: Google Cloud Managed Service for Prometheus (GMP) as an option vs. self-managed `kube-prometheus-stack`, with tradeoffs.
- ArgoCD on GKE: Artifact Registry for any custom images, GKE-specific RBAC (Workload Identity for ArgoCD's own repo/cluster credentials).
- **Deliverable:** `docs/02-gke-documentation.md`.

### Phase 13 — EKS-Native Documentation
**Goal:** `docs/03-eks-documentation.md` — same translation exercise, EKS-native.
- Cluster: EKS with managed node groups (or Fargate profile tradeoffs — Fargate has DaemonSet restrictions, same caveat as GKE Autopilot for Promtail/Node Exporter).
- Storage: `gp3` EBS CSI StorageClass replacing Minikube's `standard` class.
- Identity: IRSA (IAM Roles for Service Accounts) for any component needing AWS API access (S3-backed Loki/Tempo).
- Networking: AWS Load Balancer Controller (ALB/NLB Ingress), VPC CNI, NetworkPolicy via Calico/VPC CNI policy support.
- Long-term storage option: S3 buckets as Loki/Tempo object storage backend.
- Managed alternative note: Amazon Managed Service for Prometheus (AMP) and Amazon Managed Grafana as options vs. self-managed, with tradeoffs.
- ArgoCD on EKS: ECR for custom images, IRSA for ArgoCD's own credentials.
- **Deliverable:** `docs/03-eks-documentation.md`.

### Phase 14 — Helm Chart #1: `observability-gke`
**Goal:** Package the validated design as an installable, GKE-native Helm chart.
- `charts/observability-gke/` wrapping the same components (kube-prometheus-stack, Loki, Tempo, dashboards, alert rules) as subchart dependencies or templated manifests, with `values.yaml` defaults pre-set for GKE: `storageClassName: premium-rwo`, GCE Ingress annotations, Workload Identity service-account annotations, GCS backend config toggles.
- Chart README documenting install against a real GKE cluster.
- **Deliverable:** `charts/observability-gke/` (Chart.yaml, values.yaml, templates/, README.md).

### Phase 15 — Helm Chart #2: `observability-eks`
**Goal:** Same, EKS-native.
- `charts/observability-eks/` with `values.yaml` defaults for EKS: `storageClassName: gp3`, ALB Ingress annotations, IRSA service-account annotations, S3 backend config toggles.
- Chart README documenting install against a real EKS cluster.
- **Deliverable:** `charts/observability-eks/`.

### Phase 16 — Helm Chart Validation
**Goal:** Both charts are structurally correct even though we can't deploy to real GKE/EKS here.
- `helm lint` both charts.
- `helm template` both charts and validate rendered output (e.g. via `kubeconform`/`kube-linter` if available).
- Smoke-test render against Minikube context with cloud-specific values overridden to Minikube-compatible values, confirming templates are parameterized correctly (not hardcoded to one cloud).
- **Deliverable:** clean lint/template output, recorded in `docs/04-helm-charts.md`.

### Phase 17 — Final Reference Documentation
**Goal:** One document that ties everything together for someone reading this repo cold.
- `README.md` at repo root: project overview, architecture diagram, links to all docs, "how to reproduce on Minikube," "how to install on GKE," "how to install on EKS."
- `docs/04-helm-charts.md`: chart design decisions, values reference, install instructions for both charts.
- A **traceability matrix**: goal → Minikube artifact → GKE doc section → EKS doc section → Helm chart values, so every requirement in Section 2 is explicitly checked off against the file(s) that satisfy it.
- **Deliverable:** `README.md`, `docs/04-helm-charts.md`, completed checklist from Section 2.

### Phase 18 — (Stretch) CI Validation
**Goal:** Optional hardening once the core deliverable is done — keeps the GitOps history trustworthy going forward.
- GitHub Actions (or equivalent) workflow: `helm lint`/`helm template` on both charts, `kubeconform` on `manifests/`, on every push — catches drift before ArgoCD ever syncs a broken manifest.
- **Deliverable:** `.github/workflows/validate.yaml`.
- Only pursue this after Phase 17 is complete and if a remote CI-capable git host (GitHub/GitLab) is in use.

---

## 6. Working Agreement

- We execute this **one phase at a time**, in order. I'll report validation results at the end of each phase before moving on.
- Every phase's output lands in the repo layout in Section 4 (across both repos) — nothing is thrown away or left undocumented.
- Phase 8 requires a GitHub account/remote reachable from this machine to host `observability-sample-app` and its GHCR image — confirm access when we reach it, before scaffolding the app.
- Cloud-specific phases (12, 13, 14, 15) are **documentation and packaging**, not live deployment — we don't have a GKE/EKS cluster to deploy to here; they are written to be directly actionable against a real cluster later, and Helm charts are validated via lint/template rather than a live cloud install.
- If scope needs to shrink or grow mid-way (e.g. dropping Tempo, or adding a service mesh), we revisit this plan.md and update it rather than silently drifting from it.
