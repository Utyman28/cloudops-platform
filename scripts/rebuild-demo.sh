#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Terraform (dev)"
cd terraform/environments/dev
terraform init -input=false
terraform apply -auto-approve
cd "$ROOT_DIR"

echo "==> kubeconfig"
aws eks update-kubeconfig --region ca-central-1 --name cloudops-dev-eks >/dev/null

echo "==> ingress-nginx (NLB via values file)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/ingress-nginx-values.yaml

echo "==> apps"
kubectl create ns apps >/dev/null 2>&1 || true
kubectl apply -f k8s/apps

echo "==> status"
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl get ingress -A
