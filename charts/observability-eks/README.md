# observability-eks

An EKS-native Helm chart packaging the observability stack validated on Minikube in
[Kubernetes-grafana-prometheus](https://github.com/Siddharthasanapala/observability-monitoring-prom-graf-k8s):
Prometheus (HA, 2 replicas), Grafana, Alertmanager (HA, 3 replicas), Loki, Tempo, an OTel
Collector, plus dashboards and alert rules as code. Sibling of
[`charts/observability-gke`](../observability-gke/) — same structure, same underlying subchart
versions, only the cloud-specific values differ. See
[`docs/03-eks-documentation.md`](../../docs/03-eks-documentation.md) in the parent repo for the
full Minikube→EKS translation reasoning this chart's defaults are built from.

## Prerequisites

- An EKS cluster on **managed node groups** (not Fargate — see "Managed node groups vs Fargate"
  below), with an IAM OIDC provider associated (`--with-oidc`):
  ```bash
  eksctl create cluster \
    --name observability-platform --region <region> --version 1.31 \
    --nodegroup-name standard-workers --node-type m5.xlarge --nodes 3 \
    --with-oidc
  ```
- `kubectl`, `helm` (v3.14+, for OCI/dependency support), pointed at that cluster.
- A `gp3` StorageClass (EKS does not set this as default out of the box — create it):
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: gp3
  provisioner: ebs.csi.aws.com
  parameters: {type: gp3, encrypted: "true"}
  volumeBindingMode: WaitForFirstConsumer
  ```
  Requires the [Amazon EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
  add-on enabled on the cluster.

## Install

```bash
cd charts/observability-eks
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

### Enabling the S3 storage backend

Loki and Tempo default to PVC-backed (`gp3`) storage, matching the validated Minikube design.
For the enterprise-scale path (see
[`docs/03-eks-documentation.md`](../../docs/03-eks-documentation.md) §5), layer
`values-s3-backend.yaml` on top — read that file's header comment first, it lists the S3 buckets
and IRSA role bindings you need to create *before* installing with it.

### Exposing Grafana externally

Requires the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
installed in-cluster first (not part of this chart). Then set
`kube-prometheus-stack.grafana.ingress.enabled: true` and fill in `hosts` + an ACM certificate
ARN annotation — disabled by default because a fresh install has no hostname or cert ready yet.
See the `ingress:` block in `values.yaml` for the ALB-native annotations already staged there.

## Managed node groups vs Fargate

This chart is built for **EKS managed node groups**. Two of its components — node-exporter
(part of the `kube-prometheus-stack` subchart, via
`prometheus-node-exporter.namespaceOverride: kube-system`) and Promtail (the companion install
above) — need `hostNetwork`/`hostPID`/`hostPath`, and **Fargate does not support DaemonSets at
all** (verified against current AWS documentation — not a curated allowlist like GKE Autopilot,
an absolute restriction: Fargate gives every pod its own dedicated micro-VM, so there is no
shared node for a DaemonSet to run on). Additionally, **the EBS CSI driver's node component is
EC2-only** — Fargate pods cannot mount `gp3`-backed PVCs at all, which rules out this chart's
default storage for Prometheus/Loki/Tempo themselves on Fargate, independent of the DaemonSet
question. If you're targeting Fargate:
- Set `kube-prometheus-stack.prometheus-node-exporter.enabled: false` and use **Amazon Managed
  Service for Prometheus (AMP)** for node-level metrics instead.
- Skip the Promtail install and use a **Fluent Bit sidecar per pod** (or Fargate's own logging
  configuration) instead of self-managed log shipping.
- Layer `values-s3-backend.yaml` — it's closer to mandatory than optional on Fargate.

Full reasoning: [`docs/03-eks-documentation.md`](../../docs/03-eks-documentation.md) §1.

## Design decisions

**Everything in one namespace, unlike the Minikube reference implementation.** The Minikube
implementation ([`docs/01-minikube-implementation.md`](../../docs/01-minikube-implementation.md)
§Phase 3) splits `observability`/`logging`/`tracing`/`demo-app` for multi-tenancy demonstration
purposes. This chart collapses `kube-prometheus-stack`/`loki`/`tempo`/`otel-collector` into one
namespace (`observability` by default) because it's a *real constraint*, not a style choice —
identical reasoning and identical finding to the sibling `charts/observability-gke` chart: the
`grafana/tempo` chart has no `namespaceOverride` at all, so it can't be split out, and a partial
split (Loki/OTel-collector elsewhere, Tempo stuck in the release namespace) would be more
confusing than useful. Node-exporter (via its own subchart's `namespaceOverride`) and Promtail
(separate release, no `namespaceOverride` available at all) remain split out to `kube-system`,
since that one is a hard host-access requirement, not a preference.

**RBAC / NetworkPolicy / Pod Security Standard hardening is not bundled.** Same reasoning as
`charts/observability-gke`: the Minikube reference implementation's Phase 3-4 multi-tenancy and
security baseline is real, validated, enterprise-shaped design — but it's a platform/security-team
concern applied *around* an observability stack, not something this chart should assume or
dictate for every consumer.

**The bundled dashboard and SLO alert rule are the same design as `observability-gke`** — a
generic `platform-overview.json` (not a port of the sample-app-specific
`sample-app-overview.json`, since this chart doesn't deploy that workload), and a
disabled-by-default, parameterized SLO example (`alertRules.slo.enabled: false`) rather than a
working alert out of the box. See `charts/observability-gke/README.md`'s "Design decisions" for
the full reasoning — it applies here verbatim, only the cloud underneath differs.

**`node-health` and `pod-crashloops` alert rules are generic and enabled by default** — they
depend only on `node_exporter`/`kube-state-metrics` metrics, which this chart always deploys
(on managed node groups), so unlike the SLO example there's no reason to ship them disabled.

## What this chart does not do

- Does not create AWS infrastructure (the cluster itself, S3 buckets, IAM roles/OIDC provider,
  Route53 records, ACM certificates, the AWS Load Balancer Controller) — all prerequisites, not
  chart responsibilities.
- Does not deploy a workload to observe (that's `observability-sample-app`, a separate repo — see
  the parent project's Phase 8).
- Does not apply RBAC/NetworkPolicy/PSS hardening (see "Design decisions" above).
- Does not install Promtail as part of `helm install` (see "Installing Promtail" above).

## IRSA vs EKS Pod Identity

This chart's `serviceAccount.annotations` values use IRSA (`eks.amazonaws.com/role-arn`), since
that's what the parent plan specifies and it's the only option that also covers Fargate. AWS's
current guidance (verified, not assumed — see
[`docs/03-eks-documentation.md`](../../docs/03-eks-documentation.md) §3) recommends **EKS Pod
Identity** instead for new workloads on managed node groups — simpler trust policies, no OIDC
provider wiring. If deploying fresh on managed node groups only, consider Pod Identity's
`PodIdentityAssociation` mechanism in place of the `serviceAccount.annotations` shown in
`values-s3-backend.yaml` — the rest of this chart is unaffected either way.

## Values reference

See `values.yaml` for the full set, organized by subchart (`kube-prometheus-stack:`, `loki:`,
`tempo:`, `otel-collector:`) plus this chart's own `namespace`, `dashboards`, and `alertRules`
keys. Every EKS-specific override (`storageClassName: gp3`, `serviceAccount.annotations` for
IRSA, the Grafana `ingress` block) is commented in place explaining why it differs from the
Minikube values it was ported from.
