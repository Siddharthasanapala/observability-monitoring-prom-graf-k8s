# EKS-Native Documentation

Translates every component built in [`01-minikube-implementation.md`](01-minikube-implementation.md)
to its EKS-native equivalent, mirroring [`02-gke-documentation.md`](02-gke-documentation.md)'s
structure. Documentation-only phase, same caveat as the GKE document — no live EKS cluster
behind these decisions. Several facts below (Pod Identity's current status relative to IRSA,
Fargate's DaemonSet support, VPC CNI's native NetworkPolicy support, AMP's ingestion mechanism)
were verified against current AWS documentation rather than recalled from memory, since AWS's
identity and networking story has moved meaningfully since general Kubernetes knowledge would
assume — called out explicitly where that mattered.

**How to read this:** `[01 §Phase N]` cites the Minikube implementation section being replaced,
same convention as the GKE document.

---

## 1. Cluster: EKS managed node groups vs Fargate

**Replaces:** [`scripts/01-setup-minikube.sh`](../scripts/01-setup-minikube.sh) · [01 §Phase 1]

| | EKS managed node groups | Fargate profiles |
|---|---|---|
| Node management | You size/scale EC2 node groups | AWS provisions one micro-VM per pod, no node management |
| DaemonSets | Unrestricted | **Not supported at all** — not a curated allowlist like GKE Autopilot, an absolute restriction. Kubernetes DaemonSets guarantee one pod per node; Fargate gives every pod its own dedicated node, so the concept doesn't apply. AWS's own documented workaround is to run the daemon as a **sidecar container in each pod** instead |
| Node-exporter (Phase 5) | Runs unmodified — same `namespaceOverride: kube-system` trick, same `hostNetwork`/`hostPID`/host `/proc`,`/sys` mounts as Minikube | Does not run as designed at all — no per-node DaemonSet concept exists on Fargate to attach to |
| Promtail (Phase 6) | Runs unmodified | Same restriction; AWS's Fargate logging story is a per-pod log router sidecar (`fluent-bit` as a sidecar, configured via the Fargate profile's logging configuration) instead of a cluster-wide DaemonSet |
| EBS CSI node DaemonSet | Works | **Also doesn't work on Fargate** — the EBS CSI driver's node component is EC2-only, meaning Fargate pods cannot mount EBS-backed PVCs at all. This alone rules out Fargate for Prometheus/Loki/Tempo's own PVC-backed storage, independent of the DaemonSet question |

**Recommendation:** managed node groups, for the same reason GKE Standard was recommended over
Autopilot in the GKE document — this is the direct, unmodified lift-and-shift of everything
validated on Minikube. Fargate is a materially bigger architecture change here than GKE Autopilot
was: Autopilot at least allows a curated set of system DaemonSets and doesn't block EBS-equivalent
PVC mounting; Fargate blocks both outright. A Fargate-based deployment of this stack would need
node-exporter dropped entirely (rely on CloudWatch Container Insights or AMP's own infrastructure
metrics instead), Promtail replaced by per-pod Fluent Bit sidecars, and Prometheus/Loki/Tempo's
storage reconsidered since they can't mount EBS volumes on Fargate at all (S3-backed storage, §5,
becomes closer to mandatory rather than an upgrade path).

**Cluster creation** (managed node group, matching the GKE doc's sizing):
```bash
eksctl create cluster \
  --name observability-platform \
  --region <region> \
  --version 1.31 \
  --nodegroup-name standard-workers \
  --node-type m5.xlarge \
  --nodes 3 \
  --with-oidc
```
`--with-oidc` associates an IAM OIDC provider with the cluster — required for IRSA (§3).

## 2. Storage: `gp3` EBS CSI StorageClass

**Replaces:** Minikube's `standard` StorageClass · [01 §Phase 1, §Phase 5-7]

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
```

Same mechanical translation as the GKE document's `standard-rwo` — every `storageClassName:
standard` in
[`manifests/kube-prometheus-stack/values.yaml`](../manifests/kube-prometheus-stack/values.yaml),
[`manifests/loki/values.yaml`](../manifests/loki/values.yaml), and
[`manifests/tempo/values.yaml`](../manifests/tempo/values.yaml) becomes `storageClassName: gp3`.
One EKS-specific detail Minikube's hostpath storage has no equivalent for:
**`volumeBindingMode: WaitForFirstConsumer`** matters on EKS in a way it doesn't on
single-node Minikube — EBS volumes are zone-locked, so the PVC must not bind until the pod
that will use it is scheduled, otherwise Prometheus/Loki/Tempo's pod and its volume can end up
in different Availability Zones and simply never start. The EKS-native `gp3` StorageClass (unlike
the AWS default `gp2` class some clusters ship with) is not automatically the cluster default —
it must be explicitly created and set as default, or referenced by name as above.

## 3. Identity: IRSA (and EKS Pod Identity)

**Replaces:** nothing in the Minikube implementation, same as the GKE document's §3 — this
concept doesn't exist there. The two concrete needs are the same as GKE: **Loki/Tempo writing to
S3** (§5) and **ArgoCD/the sample app pulling from a private ECR repository** (§7).

**IRSA (IAM Roles for Service Accounts)** — the mechanism the plan names explicitly:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki
  namespace: logging
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/loki-s3-access
```
paired with an IAM trust policy scoped to the cluster's OIDC provider
(`--with-oidc` from §1) and the specific `system:serviceaccount:logging:loki` subject. No key
material as a Kubernetes Secret, same property as GKE's Workload Identity.

**Worth flagging explicitly** (verified against current AWS guidance, not assumed): AWS now
recommends **EKS Pod Identity**, not IRSA, as the default for *new* workloads on EC2 managed node
groups as of 2026 — it removes the OIDC-provider wiring entirely in favor of an AWS-managed
identity agent, with simpler trust policies and portable IAM roles across clusters. **IRSA is
still required for Fargate workloads** (Pod Identity doesn't support Fargate), so a
mixed EC2/Fargate cluster would use both. Since every workload in this stack (Loki, Tempo, the
sample app) is recommended to run on managed node groups anyway (§1), **Pod Identity is the more
current choice** for a fresh EKS deployment of this repo — documented here as IRSA because
that's what the plan specifies, with this note so the choice is a deliberate one, not a stale
default.

## 4. Networking: ALB/NLB, VPC CNI, NetworkPolicy

**Replaces:** Minikube's `ingress` addon (nginx) [01 §Phase 1], and the `--cni=calico`
NetworkPolicy enforcement finding [01 §Phase 4].

**Ingress.** The [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
replaces nginx-ingress, provisioning a real **Application Load Balancer** (`Ingress` objects,
`alb.ingress.kubernetes.io/*` annotations — e.g. `target-type: ip` to route directly to pod IPs
rather than via NodePort) or **Network Load Balancer** (for `Service type: LoadBalancer`, L4).
Same caveat as the GKE document: no `Ingress` object exists anywhere in this repo's Minikube
implementation — Grafana/ArgoCD were reached via `kubectl port-forward` throughout [01 §Phase
5-10] — a real EKS deployment adds these fresh, they don't already exist to "translate."

**VPC CNI.** Amazon VPC CNI is the default and only AWS-supported CNI for EKS on EC2 nodes (the
GKE document's Dataplane V2 has no direct EKS equivalent as a *default*; VPC CNI's role is
closer to Minikube's replaced `bridge` CNI, not to Calico).

**NetworkPolicy — this is the one place the plan's own phrasing needed updating against current
reality.** The plan frames this as "NetworkPolicy via Calico/VPC CNI policy support," implying a
choice; as of VPC CNI **v1.14.0+** (requires Kubernetes 1.25+, EKS-optimized AMI kernel 5.10+),
**VPC CNI enforces standard Kubernetes `NetworkPolicy` natively**, via an eBPF-based Amazon
Network Policy Controller — no separate CNI/policy engine needed at all. This is the direct EKS
equivalent of Minikube's `--cni=calico` finding [01 §Phase 4: "Minikube's default bridge CNI does
not enforce NetworkPolicy at all"] — same underlying lesson (enforcement is never automatic,
must be deliberately enabled), different mechanism (a VPC CNI feature flag, not a CNI swap):
```bash
kubectl set env daemonset aws-node -n kube-system ENABLE_NETWORK_POLICY=true
```
Every rule in [`manifests/network-policies/`](../manifests/network-policies/) — `default-deny-all`
plus explicit allows — is portable as-is under native VPC CNI enforcement, **except** one
concrete limitation worth checking against this repo's actual rules: native VPC CNI NetworkPolicy
does not support Service port translation — the policy's port must match the container's port
exactly, not the Service's port if they differ. This repo's rules already target container ports
directly (e.g. `port: 3100` for Loki, `port: 4317`/`4318` for OTLP) so this limitation doesn't
bite here, but it's a real constraint worth knowing before adding new rules. **Calico remains
available** as an optional policy engine layered on top of VPC CNI (not replacing it) for
clusters wanting Calico's richer `GlobalNetworkPolicy` CRDs beyond what standard `NetworkPolicy`
covers — not required for anything in this repo.

The [01 §Phase 4] node-IP `ipBlock` rules (Minikube-specific, targeting `192.168.49.2` because
Calico-on-Minikube evaluates egress after kube-proxy's DNAT) have the same "does not translate"
status as in the GKE document — EKS's control plane is a separate AWS-managed VPC, not a cluster
node, so there's no node IP to target; API-server reachability needs no NetworkPolicy exception
under native VPC CNI enforcement in the way it did on Minikube.

## 5. Long-term storage: S3 for Loki/Tempo

**Replaces:** `loki.storage.type: filesystem` in
[`manifests/loki/values.yaml`](../manifests/loki/values.yaml) and `tempo.storage.trace.backend:
local` in [`manifests/tempo/values.yaml`](../manifests/tempo/values.yaml) · [01 §Phase 6-7]

```yaml
# Loki
loki:
  storage:
    type: s3
    s3:
      region: <region>
      # bucket via ServiceAccount + IRSA/Pod Identity (§3), no static keys
```
```yaml
# Tempo
tempo:
  storage:
    trace:
      backend: s3
      s3:
        bucket: <bucket>
        region: <region>
```

Same reasoning as the GKE document's §5: this is an architecture change (decouples retention from
a single StatefulSet replica's disk), not just a values swap, and directly addresses the class of
problem behind Tempo's real OOMKill incident in [01 §Phase 9] (WAL replay pressure on restart —
S3-backed Tempo doesn't accumulate the same local WAL). On Fargate specifically (§1), S3-backed
storage is closer to mandatory than optional, since EBS-backed PVCs aren't mountable there at all.

## 6. Managed alternative: Amazon Managed Service for Prometheus + Amazon Managed Grafana

**Replaces (as an alternative to, not a required change from):**
[`manifests/kube-prometheus-stack/values.yaml`](../manifests/kube-prometheus-stack/values.yaml) ·
[01 §Phase 5]

| | Self-managed `kube-prometheus-stack` (this repo, as built) | AMP + Amazon Managed Grafana |
|---|---|---|
| Operational burden | You own upgrades, sizing — the exact issues found in [01 §Phase 5] | AWS-managed, zero sizing/upgrade burden for the Prometheus-compatible backend |
| Ingestion mechanism | Native Prometheus scrape | **Remote-write only** — AMP has no scrape mechanism of its own. Either point Prometheus's own `remote_write` at AMP (keep self-managed Prometheus scraping, forward everything to AMP), or run the **ADOT Collector** (AWS's OpenTelemetry Collector distribution — the same technology already deployed in this repo for traces, [01 §Phase 7]) configured with a Prometheus receiver + `prometheusremotewrite` exporter + SigV4 auth extension. This repo's existing `manifests/tempo/otel-collector-values.yaml` is a working example of exactly this receiver/exporter pipeline shape, already proven — an AMP-bound collector would add a `prometheusremotewrite` exporter to a config of that same shape, not build one from scratch |
| PromQL compatibility | Native | Native (Prometheus-compatible query API) |
| Grafana | Self-hosted (this repo's Grafana) — still needed for dashboards regardless | Amazon Managed Grafana as a fully-managed alternative, or keep self-hosted Grafana pointed at AMP's query endpoint — both valid |
| Alertmanager | Self-managed, 3 replicas [01 §Phase 5] | AMP supports Prometheus-compatible alerting rules evaluated within the managed service; self-managed Alertmanager can still consume them, or route through AMP's own alert manager integration |

**Recommendation:** same logic as the GKE document — self-managed `kube-prometheus-stack` is the
right choice for a managed-node-group EKS deployment, since it's the already-proven, direct
lift-and-shift. AMP becomes more compelling specifically if Fargate is chosen (§1) — since
self-managed Prometheus's own PVC-backed storage isn't viable there anyway — or at a scale where
Prometheus's operational overhead (the exact class of findings in [01 §Phase 5] and [01 §Phase
9]) outweighs running it yourself.

## 7. ArgoCD on EKS

**Replaces:** [`bootstrap/argocd-install/`](../bootstrap/argocd-install/) · [01 §Phase 2]

ArgoCD's own installation (vendored `install.yaml`, `kubectl apply --server-side` — [01 §Phase
2]'s CRD-size workaround) is identical on EKS; nothing about that install is Minikube-specific.
Two things change, mirroring the GKE document's §7:

**Amazon ECR**, not GHCR, for `observability-sample-app` — currently public on GHCR [01 §Phase
8], fine for a demo but would move to ECR (`<account-id>.dkr.ecr.<region>.amazonaws.com/observability-sample-app`)
for a real AWS deployment, with the CI workflow's `docker/login-action` swapped for
`aws-actions/amazon-ecr-login`, and the Deployment's image pull authenticated via the node's
own IAM role (EC2 managed node groups) rather than an `imagePullSecret` — same "no key material
as a Secret" property as GKE's Artifact Registry case.

**IRSA/Pod Identity for ArgoCD itself**, if it needs to pull Helm charts from a private ECR OCI
repo — not needed today, since `prometheus-community`, `grafana`, and `open-telemetry` are all
public chart repos, same as the GKE document's equivalent note.

Everything else — the App-of-Apps pattern, all 13 child `Application` manifests in
[`argocd-apps/`](../argocd-apps/), the "write a manifest → drop an Application file → commit →
push" workflow from [01 §Phase 2] — is 100% portable, unchanged.

---

## 8. Full component translation table

| Minikube component | File(s) | EKS-native equivalent | Section |
|---|---|---|---|
| Cluster | `scripts/01-setup-minikube.sh` | EKS managed node group, `--with-oidc` | §1 |
| `standard` StorageClass | all three Helm values files | `gp3` (`ebs.csi.aws.com`, `WaitForFirstConsumer`) | §2 |
| `ingress` addon (nginx) | Phase 1 addon, unused beyond enable | AWS Load Balancer Controller (ALB/NLB) | §4 |
| `--cni=calico` | `scripts/01-setup-minikube.sh` | VPC CNI native NetworkPolicy (`ENABLE_NETWORK_POLICY=true`) | §4 |
| NetworkPolicy content | `manifests/network-policies/` | Portable as-is, except node-IP `ipBlock` rules; watch the no-port-translation limitation | §4 |
| cert-manager + self-signed issuer | `manifests/cert-manager/`, `manifests/security/` | cert-manager unchanged + ACM-issued certs via ALB, or `cert-manager` with an ACME/Route53 issuer | — |
| RBAC (Groups) | `manifests/rbac/` | Unchanged — bind the same Groups to a real OIDC/IAM Identity Center group claim | — |
| kube-prometheus-stack | `manifests/kube-prometheus-stack/values.yaml` | Unchanged on managed node groups; replace with AMP on Fargate or at scale | §1, §6 |
| node-exporter | subchart of above | Unchanged on managed node groups; **not viable at all** on Fargate | §1 |
| Loki (filesystem storage) | `manifests/loki/values.yaml` | S3 backend | §5 |
| Promtail | `manifests/loki/promtail-values.yaml` | Unchanged on managed node groups; **not viable at all** on Fargate — Fluent Bit sidecar per pod instead | §1 |
| Tempo (local storage) | `manifests/tempo/values.yaml` | S3 backend | §5 |
| OTel Collector | `manifests/tempo/otel-collector-values.yaml` | Unchanged; same pipeline shape reusable for an AMP-bound collector (§6) | §6 |
| Sample app image (GHCR) | `manifests/sample-app/deployment.yaml` | ECR + IRSA/Pod Identity | §7 |
| Dashboards/alert rules | `manifests/dashboards/`, `manifests/alert-rules/` | Unchanged — pure Grafana/PrometheusRule content, no cloud dependency | — |
| `scripts/validate.sh` | Phase 10 | Same checks; all portable, `kubectl exec`-into-Grafana-pod technique unchanged | — |

## 9. What does not change at all

Same statement as the GKE document, verbatim in substance: the **GitOps mechanism** (ArgoCD
App-of-Apps, every child Application's structure, commit→push→reconcile), the **RBAC design**,
the **PSS-restricted namespace strategy**, the **NetworkPolicy default-deny structure**, the
**dashboard/alert-rule content**, and the **sample app itself** are all 100% portable. Comparing
this document against the GKE one, the *shape* of what changes is identical across both clouds
(cluster mode choice, storage class, identity federation, ingress controller, object storage,
managed-service alternative, image registry) even though the specific mechanisms differ — which
is itself evidence the Minikube implementation was built at the right level of abstraction: the
90% that's pure Kubernetes stayed pure Kubernetes.
