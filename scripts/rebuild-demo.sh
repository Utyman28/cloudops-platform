#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# REQUIREMENTS
############################################
for cmd in aws kubectl helm terraform jq dig curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "❌ Missing required command: $cmd"
    exit 1
  }
done

############################################
# CONFIG (override via env vars)
############################################
AWS_REGION="${AWS_REGION:-ca-central-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-cloudops-dev-eks}"

# Route53 (optional but recommended)
# Accept either "ZXXXX" or "/hostedzone/ZXXXX"
ROUTE53_ZONE_ID_RAW="${ROUTE53_ZONE_ID:-}"
ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID_RAW#/hostedzone/}"
ROUTE53_RECORD_NAME="${ROUTE53_RECORD_NAME:-}"   # e.g. app.utieyincloud.com

# App info
APP_NS="${APP_NS:-apps}"
APP_HOST="${APP_HOST:-app.utieyincloud.com}"
APP_INGRESS_NAME="${APP_INGRESS_NAME:-hpa-demo}"
APP_POD_SELECTOR="${APP_POD_SELECTOR:-app=hpa-demo}"

TF_DIR="terraform/environments/dev"

############################################
# HELPERS
############################################
log(){ echo -e "\n==> $*"; }

on_err() {
  echo -e "\n❌ Error on line $1. Quick status:\n"
  kubectl get ns 2>/dev/null || true
  kubectl -n ingress-nginx get deploy,po,svc 2>/dev/null || true
  kubectl -n "${APP_NS}" get deploy,po,svc,ing 2>/dev/null || true
}
trap 'on_err $LINENO' ERR

wait_for_jsonpath() {
  # usage: wait_for_jsonpath <cmd> <tries> <sleep>
  local cmd="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-5}"

  local out=""
  for _ in $(seq 1 "$tries"); do
    out="$(eval "$cmd" 2>/dev/null || true)"
    if [[ -n "$out" && "$out" != "None" ]]; then
      echo "$out"
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

############################################
# (Optional) Verify Route53 hosted zone
############################################
if [[ -n "$ROUTE53_ZONE_ID" ]]; then
  log "Verify Route53 hosted zone id: ${ROUTE53_ZONE_ID}"
  if ! aws route53 get-hosted-zone --id "$ROUTE53_ZONE_ID" >/dev/null 2>&1; then
    echo "❌ Route53 hosted zone NOT found for id: ${ROUTE53_ZONE_ID}"
    echo "   Tip: your correct zone id should look like: Z00794961JZ34C39HZ71B"
    echo "   You can re-check with:"
    echo "   aws route53 list-hosted-zones-by-name --dns-name utieyincloud.com --max-items 1"
    exit 1
  fi
  echo "✅ Route53 zone verified: ${ROUTE53_ZONE_ID}"
else
  log "Route53 zone verification skipped (ROUTE53_ZONE_ID not set)"
fi

############################################
# Terraform apply
############################################
log "Terraform apply (${TF_DIR})"
pushd "$TF_DIR" >/dev/null
terraform init -input=false
terraform apply -auto-approve
popd >/dev/null

############################################
# kubeconfig
############################################
log "Update kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" >/dev/null

############################################
# ingress-nginx
############################################
log "Install/upgrade ingress-nginx (NLB)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/ingress-nginx-values.yaml

log "Wait for ingress-nginx controller"
kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=300s

# Defensive: enforce 443-only on Service (long-term keep it in Helm values)
log "Enforce ingress-nginx Service is 443-only (defensive)"
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  --type='merge' \
  -p '{
    "spec": { "ports": [ { "name":"https", "port":443, "protocol":"TCP", "targetPort":"http" } ] }
  }' >/dev/null 2>&1 || true

############################################
# Wait for NLB hostname
############################################
log "Wait for NLB hostname"
NLB_HOSTNAME="$(wait_for_jsonpath "kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" 80 5)" || {
  echo "❌ Timed out waiting for NLB hostname"
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide || true
  exit 1
}
echo "✅ NLB: ${NLB_HOSTNAME}"

############################################
# Deploy apps
############################################
log "Deploy apps"
kubectl create ns "$APP_NS" >/dev/null 2>&1 || true
kubectl apply -f k8s/apps

log "Wait for app pods Ready"
kubectl -n "$APP_NS" wait --for=condition=Ready pod -l "$APP_POD_SELECTOR" --timeout=300s

log "Wait for Ingress ADDRESS"
ING_ADDR="$(wait_for_jsonpath "kubectl -n ${APP_NS} get ingress ${APP_INGRESS_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" 80 5)" || {
  echo "❌ Timed out waiting for ingress status address"
  kubectl -n "$APP_NS" get ingress "$APP_INGRESS_NAME" -o wide || true
  exit 1
}
echo "✅ Ingress address: ${ING_ADDR}"

############################################
# Route53 alias update (optional)
############################################
if [[ -n "$ROUTE53_ZONE_ID" && -n "$ROUTE53_RECORD_NAME" ]]; then
  log "Route53 UPSERT alias: ${ROUTE53_RECORD_NAME} -> ${NLB_HOSTNAME}"

  # Find the CanonicalHostedZoneId for this specific LB DNSName
  NLB_ZONE_ID="$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='${NLB_HOSTNAME}'].CanonicalHostedZoneId | [0]" \
    --output text)"

  if [[ -z "$NLB_ZONE_ID" || "$NLB_ZONE_ID" == "None" ]]; then
    echo "❌ Could not resolve NLB CanonicalHostedZoneId for DNSName=${NLB_HOSTNAME}"
    aws elbv2 describe-load-balancers --region "$AWS_REGION" --output table | head -n 80 || true
    exit 1
  fi

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ROUTE53_ZONE_ID" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${ROUTE53_RECORD_NAME}\",
          \"Type\": \"A\",
          \"AliasTarget\": {
            \"HostedZoneId\": \"${NLB_ZONE_ID}\",
            \"DNSName\": \"${NLB_HOSTNAME}\",
            \"EvaluateTargetHealth\": false
          }
        }
      }]
    }" >/dev/null

  echo "✅ Route53 UPSERT submitted"
else
  log "Route53 UPSERT skipped (set ROUTE53_ZONE_ID + ROUTE53_RECORD_NAME to enable)"
fi

############################################
# Proof checks
############################################
log "Proof: HTTPS via NLB + Host header"
for _ in {1..30}; do
  if curl -sk --max-time 5 -H "Host: ${APP_HOST}" "https://${NLB_HOSTNAME}/" >/dev/null; then
    echo "✅ HTTPS via NLB + Host header works"
    break
  fi
  echo "Waiting for NLB endpoint..."
  sleep 5
done

log "Proof: DNS + HTTPS must work"
echo "DNS: $(dig +short "${APP_HOST}" | head -n 1 || true)"
curl -sS -o /dev/null -w "HTTPS=%{http_code}\n" "https://${APP_HOST}" || true

log "Proof: HTTP must NOT work (timeout expected)"
curl -m 8 -v "http://${APP_HOST}" 2>&1 | tail -n 15 || true

############################################
# Status
############################################
log "Status"
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl -n "${APP_NS}" get ingress "${APP_INGRESS_NAME}" -o wide

log "DONE"

