#!/usr/bin/env bash
set -Eeuo pipefail

# validate-env.sh
# Purpose: Evidence-oriented validation for the EKS demo environment.
# Design principles:
# - DNS optional: Route53 may be skipped, validation must still work.
# - Metrics aware: HPA requires metrics-server; wait for readiness.
# - Time tolerant: HPA scaling is not instantaneous; observe behavior over time.

NS_INGRESS="${NS_INGRESS:-ingress-nginx}"
NS_APPS="${NS_APPS:-apps}"
APP_HOST="${APP_HOST:-app.utieyincloud.com}"
HPA_NAME="${HPA_NAME:-hpa-demo}"
DEPLOY_NAME="${DEPLOY_NAME:-hpa-demo}"
OBS_WINDOW_SECONDS="${OBS_WINDOW_SECONDS:-120}"
OBS_INTERVAL_SECONDS="${OBS_INTERVAL_SECONDS:-5}"

log(){ echo -e "\n==> $*"; }

log "Kube context"
kubectl config current-context || true

log "Nodes"
kubectl get nodes -o wide || true

log "Ingress NGINX LB (should be NLB hostname + 443)"
kubectl -n "$NS_INGRESS" get svc ingress-nginx-controller -o wide

# ----- Resolve NLB hostname/IP (DNS-optional path) -----
log "Resolve NLB hostname/IP for TLS validation"
NLB_DNS="$(kubectl -n "$NS_INGRESS" get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

if [[ -z "${NLB_DNS:-}" ]]; then
  echo "ERROR: NLB hostname not found on Service ingress-nginx-controller."
  echo "Hint: ensure ingress-nginx Service is type LoadBalancer and provisioned."
  exit 1
fi

if command -v dig >/dev/null 2>&1; then
  NLB_IP="$(dig +short "$NLB_DNS" | head -n1 || true)"
else
  NLB_IP=""
fi

echo "NLB_DNS: $NLB_DNS"
echo "NLB_IP : ${NLB_IP:-<dig not available or no A record returned>}"

log "App ingress routing"
kubectl -n "$NS_APPS" get ingress "$HPA_NAME" -o wide || true
kubectl -n "$NS_APPS" describe ingress "$HPA_NAME" | sed -n '1,140p' || true

# ----- Metrics Server readiness gate -----
log "Metrics API readiness (required for HPA)"
if kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  kubectl wait --for=condition=Available --timeout=120s apiservice/v1beta1.metrics.k8s.io || true
  kubectl get apiservice v1beta1.metrics.k8s.io || true
else
  echo "WARN: apiservice/v1beta1.metrics.k8s.io not found. HPA may show <unknown>."
fi

log "Quick metrics sanity (best-effort)"
kubectl top nodes 2>/dev/null || echo "WARN: kubectl top nodes failed"
kubectl -n "$NS_APPS" top pods 2>/dev/null || echo "WARN: kubectl top pods failed"

# ----- HTTPS validation -----
log "HTTPS should return 200 (DNS optional via --resolve)"
if [[ -n "${NLB_IP:-}" ]]; then
  curl -vk --resolve "${APP_HOST}:443:${NLB_IP}" "https://${APP_HOST}/" -o /dev/null \
    -w "HTTP %{http_code}\n" || true
else
  echo "WARN: NLB_IP not available; falling back to direct DNS lookup (may fail if Route53 skipped)."
  curl -vk "https://${APP_HOST}/" -o /dev/null -w "HTTP %{http_code}\n" || true
fi

# ----- HTTP negative test (should not be the primary path) -----
log "HTTP should NOT be reachable as the primary path"
# If DNS is not configured, this may fail to resolve. That's acceptable.
curl -I --max-time 5 "http://${APP_HOST}" || echo "OK: HTTP not reachable / timed out (expected)"

# ----- HPA observation (report, don't prematurely fail) -----
log "HPA status (min/max + current replicas)"
kubectl -n "$NS_APPS" get hpa "$HPA_NAME" -o wide || true
kubectl -n "$NS_APPS" describe hpa "$HPA_NAME" | sed -n '1,140p' || true

log "Observe HPA for ${OBS_WINDOW_SECONDS}s (every ${OBS_INTERVAL_SECONDS}s)"
ITERATIONS=$(( OBS_WINDOW_SECONDS / OBS_INTERVAL_SECONDS ))
for ((i=1; i<=ITERATIONS; i++)); do
  date -u +"%Y-%m-%d %H:%M:%S UTC"
  kubectl -n "$NS_APPS" get hpa "$HPA_NAME" --no-headers 2>/dev/null || true
  sleep "$OBS_INTERVAL_SECONDS"
done

log "Done"

