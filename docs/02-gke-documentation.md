# GKE-Native Documentation

Translates every component built in [`01-minikube-implementation.md`](01-minikube-implementation.md)
to its GKE-native equivalent. This is a documentation-only phase — there is no live GKE cluster
behind these decisions, unlike Phases 1–10 which were all live-validated on Minikube. Every claim
below is either a well-documented GCP/GKE platform behavior or an explicit, flagged assumption;
where Minikube's implementation was proven by testing and GKE's equivalent is not, that
difference is called out rather than glossed over.

**How to read this:** each section names the exact Minikube file/decision it replaces, using the
same citation style as `01-minikube-implementation.md` — `[01 §Phase N]` refers to that phase's
section there.

---

## 1. Cluster: GKE Standard vs Autopilot

**Replaces:** [`scripts/01-setup-minikube.sh`](../scripts/01-setup-minikube.sh) · [01 §Phase 1]

Minikube's `--cpus=4 --memory=8192 --cni=calico` single-node cluster stands in for a real node
pool. On GKE, the first real decision is **Standard vs Autopilot**, and it is not neutral for
this specific stack:

| | GKE Standard | GKE Autopilot |
|---|---|---|
| Node management | You provision/size node pools | Google manages nodes; you request pod resources |
| DaemonSets | Unrestricted | Restricted to a curated allowlist; arbitrary `hostPath`/`hostNetwork`/`hostPID` DaemonSets are largely disallowed |
| Node-exporter (Phase 5) | Runs unmodified, same as Minikube — `namespaceOverride: kube-system`, `hostNetwork`/`hostPID`/host `/proc`,`/sys` mounts all work | **Does not run as designed.** Autopilot's Pod Security model blocks `hostNetwork`/`hostPID` and restricts `hostPath` to a small set of system paths — the exact mechanism `manifests/kube-prometheus-stack/values.yaml`'s `prometheus-node-exporter.namespaceOverride: kube-system` relies on is unavailable |
| Promtail (Phase 6) | Runs unmodified — `hostPath` mounts of `/var/log/pods` and container runtime log dirs both work | Same restriction as node-exporter; Autopilot's own logging integration (Cloud Logging's built-in agent) is the intended path instead |
| Pricing model | Pay for provisioned nodes | Pay per pod resource request |

**Recommendation:** run this exact stack — self-managed `kube-prometheus-stack` with its own
node-exporter, self-managed Promtail — on **GKE Standard**. It is the direct, unmodified
lift-and-shift of everything validated on Minikube: same Helm charts, same values files, same
`namespaceOverride` trick, same restricted-PSS reasoning from [01 §Phase 4]. Autopilot is a
legitimate choice but changes the *architecture*, not just the deployment target — on Autopilot,
the natural path replaces node-exporter with **Google Cloud Managed Service for Prometheus (GMP)**
(§7 below) and replaces Promtail with **Cloud Logging's built-in log router** (every GKE
Autopilot cluster ships this automatically, no DaemonSet needed), rather than trying to force
this repo's DaemonSets through Autopilot's restrictions.

Everything else in this document (RBAC, NetworkPolicy, Prometheus/Grafana/Alertmanager
themselves, Loki's and Tempo's own pods, the sample app) runs identically on Standard or
Autopilot — only the two host-access DaemonSets are Standard-only as currently designed.

**Cluster creation** (Standard, VPC-native — see §4):
```bash
gcloud container clusters create observability-platform \
  --region=<region> \
  --enable-ip-alias \
  --release-channel=stable \
  --num-nodes=3 \
  --machine-type=e2-standard-4 \
  --workload-pool=<project-id>.svc.id.goog
```
`--workload-pool` enables Workload Identity cluster-wide (§3); `--enable-ip-alias` is VPC-native
mode (§4), the GKE default and the only mode compatible with Dataplane V2 NetworkPolicy
enforcement.

## 2. Storage: StorageClasses

**Replaces:** Minikube's `standard` StorageClass, used throughout
[`manifests/kube-prometheus-stack/values.yaml`](../manifests/kube-prometheus-stack/values.yaml),
[`manifests/loki/values.yaml`](../manifests/loki/values.yaml),
[`manifests/tempo/values.yaml`](../manifests/tempo/values.yaml) · [01 §Phase 1, §Phase 5-7]

GKE provisions two built-in CSI-backed StorageClasses; Minikube's single `standard` class (backed
by `k8s.io/minikube-hostpath`, confirmed via `kubectl get storageclass` in [01 §Phase 1]) maps to
whichever one matches the workload's I/O needs:

| Minikube | GKE equivalent | When |
|---|---|---|
| `standard` | `standard-rwo` (pd-balanced) | Default choice — Prometheus/Loki/Tempo's WAL and block storage, Grafana's dashboard DB |
| `standard` | `premium-rwo` (pd-ssd) | If Prometheus's 2-replica write-heavy TSDB becomes I/O-bound at real production cardinality — start with `standard-rwo`, migrate only if metrics show it's warranted |

Every `storageClassName: standard` reference in this repo's three values files becomes
`storageClassName: standard-rwo` (or `premium-rwo`) for GKE — this is the single most mechanical
translation in this whole document, and it's exactly the kind of value the two Helm charts in
Phase 14 parameterize rather than hardcode.

## 3. Identity: Workload Identity

**Replaces:** nothing in the Minikube implementation — this concept doesn't exist there. Minikube
has no GCP API surface at all; every credential need in [01 §Phase 1-10] was either
Kubernetes-native (ServiceAccount tokens) or absent entirely (no cloud storage, no cloud secrets
manager).

On GKE, any pod needing to call a GCP API — the two concrete cases in this stack are **Loki/Tempo
writing to GCS** (§5) and **ArgoCD reading a private Artifact Registry image** (§8) — authenticates
via **Workload Identity Federation for GKE**, not a downloaded service-account key file:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki
  namespace: logging
  annotations:
    iam.gke.io/gcp-service-account: loki-gcs@<project-id>.iam.gserviceaccount.com
```
paired with an IAM policy binding (`roles/iam.workloadIdentityUser`) between that GCP service
account and the Kubernetes ServiceAccount's identity
(`<project-id>.svc.id.goog[logging/loki]`). No key material ever exists as a Kubernetes Secret —
this is a strictly better security posture than anything possible on Minikube, not a workaround
for a Minikube limitation.

Every Helm chart in this repo (`grafana/loki`, `grafana/tempo`, `prometheus-community/kube-prometheus-stack`)
already exposes a `serviceAccount.annotations` value specifically for this — the GKE Helm chart
(Phase 14) sets it via a values override, the Minikube values files simply never populate it.

## 4. Networking: Ingress, DNS, VPC, NetworkPolicy

**Replaces:** Minikube's `ingress` addon (nginx controller) [01 §Phase 1], and the
`--cni=calico` NetworkPolicy enforcement finding [01 §Phase 4].

**Ingress.** Minikube's nginx ingress controller (chosen because it's the addon available
locally) becomes either:
- **GKE Ingress** (the GCE controller, `kubernetes.io/ingress.class: gce`) — provisions a real
  Google Cloud HTTP(S) Load Balancer per `Ingress` object. Simplest, most direct GKE-native
  choice, closest conceptually to what nginx-ingress does on Minikube.
- **Gateway API** — GKE's forward-looking replacement for the Ingress resource, standardized
  across Kubernetes rather than GKE-specific. Recommended for new work if there's appetite for
  the newer API surface; either works for exposing Grafana/ArgoCD UI externally.

Neither is deployed as part of this repo's Minikube work — [01 §Phase 1] enables the addon but no
`Ingress` object was ever created (Grafana/ArgoCD were reached via `kubectl port-forward`
throughout hands-on development, documented repeatedly in [01 §Phase 5-10] including its
flakiness). A real GKE deployment would add `Ingress`/`Gateway` objects for Grafana and ArgoCD
that don't exist anywhere in this Minikube implementation.

**DNS.** Cloud DNS for any real hostnames (`grafana.example.com` etc.) fronting the GCE/Gateway
load balancer above. Minikube has no equivalent — `nip.io`-style or `/etc/hosts` entries would be
the closest local analog, neither of which this repo uses (port-forward was used instead, see
above).

**VPC-native clusters.** `--enable-ip-alias` (shown in §1's cluster-creation command) is required
— GKE's Dataplane V2 (Cilium-based) NetworkPolicy enforcement, GKE's actual equivalent of what
Calico proved necessary on Minikube [01 §Phase 4: "Minikube's default bridge CNI does not enforce
NetworkPolicy at all"], **only works in VPC-native mode**. This is the GKE-side confirmation of
the exact same finding — NetworkPolicy enforcement is never automatic, it has to be deliberately
enabled, on Minikube (`--cni=calico`) and on GKE (`--enable-ip-alias`, Dataplane V2) alike.

**NetworkPolicy content.** Every rule in
[`manifests/network-policies/`](../manifests/network-policies/) — `default-deny-all` plus
explicit allows — is standard Kubernetes `NetworkPolicy` API, portable as-is. The one exception:
[01 §Phase 4]'s `ipBlock: 192.168.49.2/32` rules (targeting Minikube's node IP directly, because
Calico on this cluster evaluates egress policy *after* kube-proxy's ClusterIP→node-IP DNAT — see
[01 §Phase 4]'s NetworkPolicy finding) are **Minikube-specific and do not translate**. GKE's
control plane is not a cluster node at all (it's a separate, Google-managed VPC), so there is no
node IP to target — the kube-apiserver/kubelet-equivalent reachability rules need to be redesigned
against GKE's actual network topology (typically: no NetworkPolicy restriction is needed for
API server egress on GKE at all, since the control plane endpoint is reached via a Google-managed
path outside the VPC-native pod network that NetworkPolicy governs).

## 5. Long-term storage: GCS for Loki/Tempo

**Replaces:** `loki.storage.type: filesystem` in
[`manifests/loki/values.yaml`](../manifests/loki/values.yaml) and `tempo.storage.trace.backend:
local` (chart default, left unset) in
[`manifests/tempo/values.yaml`](../manifests/tempo/values.yaml) · [01 §Phase 6-7]

Both charts' local-filesystem/PVC storage was a deliberate Minikube-scale simplification — Loki's
values.yaml comment says exactly this ("matches Phase 1's stand-in-for-cloud-storage approach").
The enterprise-scale upgrade path for both is GCS:

```yaml
# Loki
loki:
  storage:
    type: gcs
    gcs:
      chunkBufferSize: 0
# bucket + credentials via the Workload Identity ServiceAccount from §3
```
```yaml
# Tempo
tempo:
  storage:
    trace:
      backend: gcs
      gcs:
        bucket_name: <bucket>
```

This is a genuine architecture change, not just a values swap: PVC-backed storage ties data to a
single zone and a single StatefulSet replica's disk; GCS-backed storage decouples retention from
compute entirely, is the only realistic choice once retention windows grow past what a single PD
can hold economically, and removes the exact WAL-replay-on-restart memory pressure that caused
Tempo's real OOMKill incident in [01 §Phase 9] — a GCS-backed Tempo doesn't replay a large local
WAL on every pod restart the way the PVC-backed one on Minikube does.

## 6. Managed alternative: Google Cloud Managed Service for Prometheus (GMP)

**Replaces (as an alternative to, not a required change from):**
[`manifests/kube-prometheus-stack/values.yaml`](../manifests/kube-prometheus-stack/values.yaml) ·
[01 §Phase 5]

GMP is GKE's built-in, fully-managed Prometheus-compatible metrics pipeline — every GKE cluster
(Standard and Autopilot) has it available, and Autopilot clusters lean on it by default since
self-managed node-exporter isn't viable there (§1).

| | Self-managed `kube-prometheus-stack` (this repo, as built) | GMP |
|---|---|---|
| Operational burden | You own upgrades, sizing, the exact issues found in [01 §Phase 5] (LimitRange minimums, PSS container-security patches, quota headroom) | Google-managed, zero sizing/upgrade burden |
| PromQL compatibility | Native | Native (GMP is Prometheus-compatible, same query language, same `ServiceMonitor`-like CRDs — `PodMonitoring`/`ClusterPodMonitoring`) |
| Cost model | Compute you provision | Metrics ingestion volume-based pricing |
| Grafana | Self-hosted (this repo's `kube-prometheus-stack` Grafana) — still needed for dashboards even with GMP, since GMP has no UI of its own | Same — GMP is a metrics backend, not a dashboard product; this repo's Grafana deployment stays either way, just repointed at GMP's Prometheus-compatible query endpoint instead of self-managed Prometheus |
| Alertmanager | Self-managed (3 replicas, [01 §Phase 5]) | GMP supports Prometheus-compatible alerting rules but routes through Google Cloud's own alerting, or you keep self-managed Alertmanager pointed at GMP as the rule-evaluation source |

**Recommendation:** self-managed `kube-prometheus-stack` (as built and validated on Minikube) is
the right choice for GKE Standard, since it's the direct, already-proven lift-and-shift — every
finding in [01 §Phase 5] transfers directly and the operational burden is well-understood from
having actually debugged it. GMP becomes the more natural choice specifically on Autopilot (§1),
or at a scale where Prometheus's own operational overhead (the exact class of issues in [01
§Phase 5] and [01 §Phase 9]) outweighs the value of running it yourself.

## 7. ArgoCD on GKE

**Replaces:** [`bootstrap/argocd-install/`](../bootstrap/argocd-install/) · [01 §Phase 2]

ArgoCD's own installation (vendored `install.yaml`, `kubectl apply --server-side` — [01 §Phase
2]'s CRD-size workaround) is identical on GKE; nothing about that install is Minikube-specific.
Two things change:

**Artifact Registry**, not GHCR, for anything this project builds and wants under GCP IAM
control. This repo's only custom image is `observability-sample-app` — currently public on GHCR
[01 §Phase 8], which is fine for a demo but would move to Artifact Registry
(`<region>-docker.pkg.dev/<project>/<repo>/observability-sample-app`) in a real GCP deployment,
with the CI workflow's `docker/login-action` swapped for `google-github-actions/auth` + Artifact
Registry push, and the Kubernetes Deployment's `imagePullSecrets` replaced by Workload Identity
(§3) on the node's own service account — no `imagePullSecret` at all, same "no key material as a
Secret" property as §3's GCS case.

**Workload Identity for ArgoCD itself**, if ArgoCD needs to pull Helm charts from a private
Artifact Registry OCI repo (not needed today — every chart this repo uses is public:
`prometheus-community`, `grafana`, `open-telemetry` — but would apply the moment an internal
chart repo is introduced). Same mechanism as §3, applied to ArgoCD's `argocd-repo-server`
ServiceAccount.

Everything else — the App-of-Apps pattern itself, all 13 child `Application` manifests in
[`argocd-apps/`](../argocd-apps/), the entire "write a manifest → drop an Application file →
commit → push" workflow from [01 §Phase 2] — is 100% portable, unchanged.

---

## 8. Full component translation table

| Minikube component | File(s) | GKE-native equivalent | Section |
|---|---|---|---|
| Cluster | `scripts/01-setup-minikube.sh` | GKE Standard cluster, VPC-native, `--workload-pool` | §1 |
| `standard` StorageClass | all three Helm values files | `standard-rwo` / `premium-rwo` | §2 |
| `ingress` addon (nginx) | Phase 1 addon, unused beyond enable | GKE Ingress (GCE) or Gateway API | §4 |
| `--cni=calico` | `scripts/01-setup-minikube.sh` | VPC-native + Dataplane V2 | §4 |
| NetworkPolicy content | `manifests/network-policies/` | Portable as-is, except node-IP `ipBlock` rules | §4 |
| cert-manager + self-signed issuer | `manifests/cert-manager/`, `manifests/security/` | cert-manager unchanged + Google-managed certs via GCE Ingress, or Certificate Manager | — |
| RBAC (Groups) | `manifests/rbac/` | Unchanged — bind the same Groups to a real OIDC/Google Workspace group claim | — |
| kube-prometheus-stack | `manifests/kube-prometheus-stack/values.yaml` | Unchanged on Standard; replace with GMP on Autopilot | §1, §6 |
| node-exporter | subchart of above | Unchanged on Standard; **not viable** on Autopilot — use GMP | §1 |
| Loki (filesystem storage) | `manifests/loki/values.yaml` | GCS backend | §5 |
| Promtail | `manifests/loki/promtail-values.yaml` | Unchanged on Standard; **not viable** on Autopilot — use Cloud Logging | §1 |
| Tempo (local storage) | `manifests/tempo/values.yaml` | GCS backend | §5 |
| OTel Collector | `manifests/tempo/otel-collector-values.yaml` | Unchanged | — |
| Sample app image (GHCR) | `manifests/sample-app/deployment.yaml` | Artifact Registry + Workload Identity | §7 |
| Dashboards/alert rules | `manifests/dashboards/`, `manifests/alert-rules/` | Unchanged — pure Grafana/PrometheusRule content, no cloud dependency | — |
| `scripts/validate.sh` | Phase 10 | Same checks; ArgoCD/Prometheus/Loki/Tempo/Grafana section all portable, RBAC/NetworkPolicy sections portable, `kubectl exec`-into-Grafana-pod technique unchanged | — |

## 9. What does not change at all

Worth stating explicitly, since most of this document is about what's different: the **GitOps
mechanism itself** — ArgoCD's App-of-Apps pattern, every child `Application`'s
directory-vs-Helm-source structure, the entire "commit → push → ArgoCD reconciles" workflow — the
**RBAC design** (Groups, least-privilege split between viewer/admin), the **PSS-restricted
namespace strategy**, the **NetworkPolicy default-deny structure**, the **dashboard/alert-rule
content**, and the **sample app itself** (code, OpenTelemetry instrumentation, Dockerfile) are all
100% portable, unchanged Kubernetes-native content. This is by design — the entire point of
building this on Minikube first was to prove the Kubernetes-native 90% once, so this document
only has to describe the cloud-specific 10%.
