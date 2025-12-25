#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${AWS_REGION:=ca-central-1}"
: "${EKS_CLUSTER_NAME:=cloudops-dev-eks}"

echo "==> Region: $AWS_REGION | Cluster: $EKS_CLUSTER_NAME"
echo

echo "==> kubeconfig (best-effort)"
if aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1; then
  HAVE_KUBE=1
else
  HAVE_KUBE=0
  echo "    kubeconfig update failed (cluster may already be gone). Skipping kubectl/helm steps."
fi
echo

if [ "$HAVE_KUBE" -eq 1 ]; then
  echo "==> delete apps (ingress objects first)"
  if kubectl get ns apps >/dev/null 2>&1; then
    if [ -d "k8s/apps" ]; then
      kubectl delete -f k8s/apps --ignore-not-found=true || true
    fi
    kubectl delete ns apps --ignore-not-found=true || true
  else
    echo "    apps namespace not found (ok)"
  fi
  echo

  echo "==> uninstall ingress-nginx (removes NLB owner resources)"
  if helm -n ingress-nginx status ingress-nginx >/dev/null 2>&1; then
    helm uninstall ingress-nginx -n ingress-nginx || true
  else
    echo "    helm release ingress-nginx not found (ok)"
  fi

  # Extra safety: ensure the LB Service is gone (it can outlive the helm release briefly)
  echo "==> ensure ingress-nginx controller Service is deleted (triggers NLB deletion)"
  kubectl -n ingress-nginx delete svc ingress-nginx-controller --ignore-not-found=true || true

  echo "==> wait briefly for Service deletion (best-effort)"
  kubectl -n ingress-nginx wait --for=delete svc/ingress-nginx-controller --timeout=120s >/dev/null 2>&1 || true
  echo

  # Optional cleanup (nice-to-have; can hang if AWS finalizers are slow)
  echo "==> optional namespace cleanup (best-effort)"
  kubectl delete ns ingress-nginx --ignore-not-found=true >/dev/null 2>&1 || true
  echo
fi

echo "==> Terraform destroy (dev)"
if [ -d "terraform/environments/dev" ]; then
  cd terraform/environments/dev
  terraform init -input=false >/dev/null
  terraform destroy -auto-approve
else
  echo "    terraform/environments/dev not found (skipping)"
fi
echo

echo "==> Done."
echo "NOTE: AWS can take a few minutes to fully delete the NLB + related ENIs after Service deletion."

