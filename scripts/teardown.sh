#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

AWS_REGION="${AWS_REGION:-ca-central-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-cloudops-dev-eks}"

echo "==> Using project root: $ROOT_DIR"
echo "==> Region: $AWS_REGION | Cluster: $EKS_CLUSTER_NAME"
echo

# Best-effort kubeconfig (cluster may already be gone later in the script)
echo "==> kubeconfig (best-effort)"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1 || true

# 1) Remove app layer first (Ingress objects can keep LB wiring alive)
echo "==> delete apps"
if kubectl get ns apps >/dev/null 2>&1; then
  # If you applied a folder, deleting the folder is the cleanest reversal
  if [ -d "k8s/apps" ]; then
    kubectl delete -f k8s/apps --ignore-not-found=true || true
  fi

  # Optional: if you want to remove the namespace entirely (usually you do)
  kubectl delete ns apps --ignore-not-found=true || true
else
  echo "    apps namespace not found (ok)"
fi
echo

# 2) Remove ingress-nginx (this is what created the NLB)
echo "==> uninstall ingress-nginx"
if helm -n ingress-nginx status ingress-nginx >/dev/null 2>&1; then
  helm uninstall ingress-nginx -n ingress-nginx || true
else
  echo "    helm release ingress-nginx not found (ok)"
fi

# Namespace cleanup (sometimes hangs briefly because of LB finalizers)
if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  kubectl delete ns ingress-nginx --ignore-not-found=true || true
fi
echo

# 3) Destroy Terraform infra (EKS/VPC/etc)
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
echo "NOTE: AWS may take a few minutes to fully delete the NLB + related ENIs after uninstall."

