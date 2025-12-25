#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIG
############################################
AWS_REGION="ca-central-1"
EKS_CLUSTER_NAME="cloudops-dev-eks"

# REQUIRED for Route53 alias
ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID:-}"
ROUTE53_RECORD_NAME="${ROUTE53_RECORD_NAME:-}"

############################################
# Terraform
############################################
echo "==> Terraform (dev)"
cd terraform/environments/dev
terraform init -input=false
terraform apply -auto-approve
cd -

############################################
# kubeconfig
############################################
echo "==> kubeconfig"
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$EKS_CLUSTER_NAME" >/dev/null

############################################
# ingress-nginx (NLB, HTTPS-only via values)
############################################
echo "==> ingress-nginx (NLB via values file)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/ingress-nginx-values.yaml

############################################
# Wait for Service
############################################
echo "==> wait for ingress-nginx controller Service"
kubectl -n ingress-nginx wait \
  --for=condition=Available deployment/ingress-nginx-controller \
  --timeout=300s

############################################
# Enforce HTTPS-only Service (defensive)
############################################
echo "==> enforce ingress-nginx Service is 443-only"
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  --type='merge' \
  -p '{
    "spec": {
      "ports": [
        { "name": "https", "port": 443, "protocol": "TCP", "targetPort": "http" }
      ]
    }
  }' || true

############################################
# Wait for NLB hostname
############################################
echo "==> wait for NLB hostname"
for i in {1..30}; do
  NLB_HOSTNAME=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  if [[ -n "$NLB_HOSTNAME" ]]; then
    echo "    NLB: $NLB_HOSTNAME"
    break
  fi
  sleep 10
done

############################################
# Route53 alias (ONLY if env vars provided)
############################################
if [[ -n "$ROUTE53_ZONE_ID" && -n "$ROUTE53_RECORD_NAME" ]]; then
  echo "==> Route53: update alias $ROUTE53_RECORD_NAME -> $NLB_HOSTNAME"

  # 🔑 THIS IS THE CRITICAL FIX
  NLB_ZONE_ID=$(aws elbv2 describe-load-balancers \
    --names "$(echo "$NLB_HOSTNAME" | cut -d- -f1)" \
    --region "$AWS_REGION" \
    --query 'LoadBalancers[0].CanonicalHostedZoneId' \
    --output text)

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ROUTE53_ZONE_ID" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"$ROUTE53_RECORD_NAME\",
          \"Type\": \"A\",
          \"AliasTarget\": {
            \"HostedZoneId\": \"$NLB_ZONE_ID\",
            \"DNSName\": \"$NLB_HOSTNAME\",
            \"EvaluateTargetHealth\": false
          }
        }
      }]
    }"
else
  echo "==> Route53 skipped (ROUTE53_ZONE_ID / RECORD_NAME not set)"
fi

############################################
# Apps
############################################
echo "==> apps"
kubectl create ns apps >/dev/null 2>&1 || true
kubectl apply -f k8s/apps

############################################
# Status
############################################
echo "==> status"
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl get ingress -A

