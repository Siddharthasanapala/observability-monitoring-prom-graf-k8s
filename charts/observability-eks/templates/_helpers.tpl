{{/*
Common labels for this chart's own templated resources (dashboards, alert rules) — the
subchart-managed resources (kube-prometheus-stack, Loki, Tempo, otel-collector) label themselves.
*/}}
{{- define "observability-eks.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
