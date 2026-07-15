#!/usr/bin/env bash
# Phase 10 — End-to-End Validation on Minikube
# Formal sign-off gate: every check below must pass before Phase 11 (documentation) starts.
#
# Design note: all data-plane checks (Prometheus/Loki/Tempo/Grafana) run via `kubectl exec`
# curl *from inside* the Grafana pod against in-cluster Service DNS names, not via external
# `kubectl port-forward` tunnels from the operator's machine. Port-forwards proved repeatedly
# flaky during hands-on development (stale processes holding ports, connections dying mid-check)
# — exec'ing into a pod that's already inside the cluster network sidesteps all of that and is
# also a more honest test (proves in-cluster service-to-service reachability, which is what
# actually matters, not operator-laptop reachability).
#
# Requires: kubectl (cluster access), node (JSON parsing — already a project dependency).
set -uo pipefail

PASS=0
FAIL=0
FAILURES=()

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }

GRAFANA_POD=$(kubectl get pods -n observability -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
gcurl() { kubectl exec -n observability "$GRAFANA_POD" -c grafana -- sh -c "curl -s $*" 2>/dev/null; }

echo "############################################################"
echo "# 1. ArgoCD Application sync/health status"
echo "############################################################"
if [ -z "$GRAFANA_POD" ]; then
  fail "could not find a running Grafana pod — aborting, cluster is not in a checkable state"
  echo ""; echo "=== SUMMARY: $PASS passed, $FAIL failed ==="; exit 1
fi

apps=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"\n"}{end}' 2>/dev/null)
if [ -z "$apps" ]; then
  fail "no ArgoCD Applications found"
else
  while IFS='|' read -r name sync health; do
    [ -z "$name" ] && continue
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      pass "ArgoCD app '$name' Synced/Healthy"
    else
      fail "ArgoCD app '$name' is $sync/$health (expected Synced/Healthy)"
    fi
  done <<< "$apps"
fi

echo ""
echo "############################################################"
echo "# 2. Prometheus targets"
echo "############################################################"
targets_json=$(gcurl "'http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090/api/v1/targets'")
target_summary=$(echo "$targets_json" | node -e "
let d='';process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(d);
    const t=j.data.activeTargets;
    const up=t.filter(x=>x.health==='up').length;
    const down=t.filter(x=>x.health!=='up').map(x=>x.scrapePool);
    console.log(up+'|'+down.length+'|'+down.join(','));
  } catch(e){ console.log('ERR|ERR|'+e.message); }
})")
IFS='|' read -r up_count down_count down_list <<< "$target_summary"
if [ "$up_count" = "ERR" ]; then
  fail "could not query Prometheus targets API"
elif [ "${down_count:-1}" = "0" ]; then
  pass "all $up_count Prometheus targets are up"
else
  fail "$down_count Prometheus target(s) down: $down_list"
fi

echo ""
echo "############################################################"
echo "# 3. Loki ingesting"
echo "############################################################"
loki_namespaces=$(gcurl "'http://loki.logging.svc.cluster.local:3100/loki/api/v1/label/namespace/values'")
ns_count=$(echo "$loki_namespaces" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).data.length)}catch(e){console.log('ERR')}})")
if [ "$ns_count" = "ERR" ] || [ -z "$ns_count" ]; then
  fail "could not query Loki label API"
elif [ "$ns_count" -ge 4 ]; then
  pass "Loki has log streams from $ns_count namespaces (expect ~7: argocd, cert-manager, demo-app, kube-system, logging, observability, tracing)"
else
  fail "Loki only has log streams from $ns_count namespaces — expected ingestion from most/all cluster namespaces"
fi

echo ""
echo "############################################################"
echo "# 4. Tempo receiving spans"
echo "############################################################"
tempo_search=$(gcurl "-G 'http://tempo.tracing.svc.cluster.local:3200/api/search' --data-urlencode 'q={resource.service.name=\"observability-sample-app\"}' --data-urlencode 'limit=1'")
trace_count=$(echo "$tempo_search" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log((JSON.parse(d).traces||[]).length)}catch(e){console.log('ERR')}})")
if [ "$trace_count" = "ERR" ] || [ -z "$trace_count" ]; then
  fail "could not query Tempo search API"
elif [ "$trace_count" -ge 1 ]; then
  pass "Tempo has recent spans for observability-sample-app"
else
  fail "Tempo returned no recent traces for observability-sample-app"
fi

echo ""
echo "############################################################"
echo "# 5. Grafana dashboards rendering"
echo "############################################################"
ADMIN_PWD_CHECK=$(kubectl exec -n observability "$GRAFANA_POD" -c grafana -- sh -c 'echo -n "$GF_SECURITY_ADMIN_PASSWORD" | wc -c' 2>/dev/null)
if [ "${ADMIN_PWD_CHECK:-0}" -lt 1 ]; then
  fail "Grafana admin password env var not readable from pod"
else
  dash_json=$(kubectl exec -n observability "$GRAFANA_POD" -c grafana -- sh -c 'curl -s -u "admin:${GF_SECURITY_ADMIN_PASSWORD}" "http://localhost:3000/api/dashboards/uid/sample-app-overview"' 2>/dev/null)
  panel_count=$(echo "$dash_json" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log((JSON.parse(d).dashboard.panels||[]).length)}catch(e){console.log('ERR')}})")
  if [ "$panel_count" = "ERR" ] || [ -z "$panel_count" ]; then
    fail "could not fetch/parse the sample-app-overview dashboard from Grafana (auth or provisioning issue)"
  elif [ "$panel_count" -ge 1 ]; then
    pass "Grafana dashboard 'sample-app-overview' present with $panel_count panels"
  else
    fail "Grafana dashboard 'sample-app-overview' has zero panels"
  fi
fi

echo ""
echo "############################################################"
echo "# 6. RBAC checks (least-privilege personas)"
echo "############################################################"
if kubectl auth can-i get pods -n observability --as=validate-script --as-group=sre-viewers >/dev/null 2>&1; then
  pass "sre-viewers group CAN get pods in observability (expected)"
else
  fail "sre-viewers group CANNOT get pods in observability (expected: can)"
fi
if kubectl auth can-i delete pods -n observability --as=validate-script --as-group=sre-viewers >/dev/null 2>&1; then
  fail "sre-viewers group CAN delete pods in observability (expected: cannot — least-privilege violated)"
else
  pass "sre-viewers group CANNOT delete pods in observability (expected)"
fi
if kubectl auth can-i create rolebindings -n observability --as=validate-script --as-group=observability-admins >/dev/null 2>&1; then
  fail "observability-admins group CAN create rolebindings (expected: cannot — governance objects must stay GitOps-only)"
else
  pass "observability-admins group CANNOT create rolebindings (expected — governance stays GitOps-only)"
fi
if kubectl auth can-i get secrets -n observability --as=validate-script --as-group=sre-viewers >/dev/null 2>&1; then
  fail "sre-viewers group CAN read secrets (expected: cannot)"
else
  pass "sre-viewers group CANNOT read secrets (expected)"
fi

echo ""
echo "############################################################"
echo "# 7. NetworkPolicy checks"
echo "############################################################"
for ns in observability logging tracing demo-app; do
  count=$(kubectl get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l)
  has_deny=$(kubectl get networkpolicy -n "$ns" -o jsonpath='{.items[?(@.metadata.name=="default-deny-all")].metadata.name}' 2>/dev/null)
  if [ "$count" -ge 1 ] && [ "$has_deny" = "default-deny-all" ]; then
    pass "namespace '$ns' has $count NetworkPolicies including default-deny-all"
  else
    fail "namespace '$ns' missing default-deny-all or has zero NetworkPolicies (found $count)"
  fi
done

echo ""
echo "############################################################"
echo "# SUMMARY: $PASS passed, $FAIL failed"
echo "############################################################"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "All checks passed."
exit 0
