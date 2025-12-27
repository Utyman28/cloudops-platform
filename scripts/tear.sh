#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# CONFIG (override via env if you want)
############################################
AWS_REGION="${AWS_REGION:-ca-central-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-cloudops-dev-eks}"
TF_DIR_REL="${TF_DIR_REL:-terraform/environments/dev}"

# How long to wait (seconds) for AWS deletions
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"   # 30 mins
POLL_INTERVAL="${POLL_INTERVAL:-15}"

############################################
# Logging helpers
############################################
log()  { echo -e "==> $*"; }
warn() { echo -e "WARN: $*" >&2; }
die()  { echo -e "ERROR: $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

############################################
# Resolve repo root robustly (no BASH_SOURCE)
############################################
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/${TF_DIR_REL}"

cd "${ROOT_DIR}"

############################################
# AWS helpers
############################################
awsq() { aws --region "${AWS_REGION}" "$@"; }

now_epoch() { date +%s; }

wait_until() {
  # wait_until "<desc>" <timeout_seconds> <command...>
  local desc="$1"; shift
  local timeout="$1"; shift
  local start t
  start="$(now_epoch)"
  while true; do
    if "$@"; then
      return 0
    fi
    t="$(now_epoch)"
    if (( t - start >= timeout )); then
      return 1
    fi
    sleep "${POLL_INTERVAL}"
  done
}

############################################
# Terraform helpers
############################################
tf_init_refresh() {
  if [[ ! -d "${TF_DIR}" ]]; then
    warn "Terraform dir not found: ${TF_DIR} (skipping terraform steps)"
    return 1
  fi
  log "Terraform init/refresh (${TF_DIR_REL})"
  ( cd "${TF_DIR}" && terraform init -input=false -reconfigure >/dev/null )
  # Refresh helps populate outputs (you discovered this was needed)
  ( cd "${TF_DIR}" && terraform refresh -no-color >/dev/null ) || true
  return 0
}

tf_output_raw() {
  # tf_output_raw <name>
  local name="$1"
  [[ -d "${TF_DIR}" ]] || return 1
  ( cd "${TF_DIR}" && terraform output -raw "${name}" 2>/dev/null ) || true
}

tf_destroy() {
  [[ -d "${TF_DIR}" ]] || return 1
  log "Terraform destroy (${TF_DIR_REL})"
  ( cd "${TF_DIR}" && terraform destroy -auto-approve )
}

############################################
# Kubernetes best-effort cleanup
############################################
kube_best_effort_cleanup() {
  if ! have_cmd aws || ! have_cmd kubectl || ! have_cmd helm; then
    warn "Missing aws/kubectl/helm; skipping cluster cleanup."
    return 0
  fi

  log "kubeconfig (best-effort)"
  if aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1; then
    log "Kubeconfig updated."
  else
    warn "kubeconfig update failed (cluster may already be gone). Skipping kubectl/helm steps."
    return 0
  fi

  log "Delete apps (ingress objects first) (best-effort)"
  if kubectl get ns apps >/dev/null 2>&1; then
    [[ -d "${ROOT_DIR}/k8s/apps" ]] && kubectl delete -f "${ROOT_DIR}/k8s/apps" --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete ns apps --ignore-not-found=true >/dev/null 2>&1 || true
  else
    warn "apps namespace not found (ok)"
  fi

  log "Uninstall ingress-nginx (best-effort)"
  if helm -n ingress-nginx status ingress-nginx >/dev/null 2>&1; then
    helm uninstall ingress-nginx -n ingress-nginx >/dev/null 2>&1 || true
  else
    warn "helm release ingress-nginx not found (ok)"
  fi

  log "Ensure ingress-nginx controller Service deleted (best-effort)"
  kubectl -n ingress-nginx delete svc ingress-nginx-controller --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl -n ingress-nginx wait --for=delete svc/ingress-nginx-controller --timeout=120s >/dev/null 2>&1 || true

  log "Optional namespace cleanup (best-effort)"
  kubectl delete ns ingress-nginx --ignore-not-found=true >/dev/null 2>&1 || true
}

############################################
# AWS dependency cleanup for a VPC
############################################
get_vpc_id() {
  # Prefer terraform output "vpc_id", fallback to discovering by tag if possible
  local vid=""
  vid="$(tf_output_raw vpc_id || true)"
  if [[ -n "${vid}" && "${vid}" != "null" ]]; then
    echo "${vid}"
    return 0
  fi

  # Fallback: try to find VPC tagged with cluster name (common with EKS)
  vid="$(awsq ec2 describe-vpcs \
    --filters "Name=tag:kubernetes.io/cluster/${EKS_CLUSTER_NAME},Values=owned,shared" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"

  if [[ -n "${vid}" && "${vid}" != "None" && "${vid}" != "null" ]]; then
    echo "${vid}"
    return 0
  fi

  # Last fallback: none
  echo ""
  return 1
}

delete_elbs_in_vpc() {
  local vpc_id="$1"
  log "AWS: delete ELBv2 load balancers in VPC ${vpc_id} (NLB/ALB)"

  local lbs
  lbs="$(awsq elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null || true)"

  if [[ -z "${lbs}" ]]; then
    log "No ELBv2 load balancers found in VPC."
    return 0
  fi

  for arn in ${lbs}; do
    log "Deleting LB: ${arn}"
    awsq elbv2 delete-load-balancer --load-balancer-arn "${arn}" >/dev/null 2>&1 || true
  done

  log "Waiting for ELBv2 load balancers to disappear..."
  wait_until "LBS deleted" "${WAIT_TIMEOUT}" bash -c "
    out=\$(aws --region '${AWS_REGION}' elbv2 describe-load-balancers \
      --query \"LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn\" --output text 2>/dev/null || true)
    [[ -z \"\$out\" ]]
  " || warn "Timed out waiting for ELBs to delete (continuing)."
}

delete_target_groups_in_vpc() {
  local vpc_id="$1"
  log "AWS: delete Target Groups in VPC ${vpc_id} (best-effort)"

  local tgs
  tgs="$(awsq elbv2 describe-target-groups \
    --query "TargetGroups[?VpcId=='${vpc_id}'].TargetGroupArn" --output text 2>/dev/null || true)"

  if [[ -z "${tgs}" ]]; then
    log "No target groups found in VPC."
    return 0
  fi

  for arn in ${tgs}; do
    log "Deleting TG: ${arn}"
    awsq elbv2 delete-target-group --target-group-arn "${arn}" >/dev/null 2>&1 || true
  done
}

delete_nat_gateways_in_vpc() {
  local vpc_id="$1"
  log "AWS: delete NAT Gateways in VPC ${vpc_id}"

  local nat_ids
  nat_ids="$(awsq ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${vpc_id}" \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"

  if [[ -z "${nat_ids}" ]]; then
    log "No NAT gateways found."
    return 0
  fi

  for nat in ${nat_ids}; do
    log "Deleting NAT: ${nat}"
    awsq ec2 delete-nat-gateway --nat-gateway-id "${nat}" >/dev/null 2>&1 || true
  done

  log "Waiting for NAT Gateways to reach deleted state..."
  wait_until "NAT deleted" "${WAIT_TIMEOUT}" bash -c "
    states=\$(aws --region '${AWS_REGION}' ec2 describe-nat-gateways \
      --filter 'Name=vpc-id,Values=${vpc_id}' \
      --query 'NatGateways[].State' --output text 2>/dev/null || true)
    [[ -z \"\$states\" ]] || ! echo \"\$states\" | grep -Eiq '(pending|available|deleting)'
  " || warn "Timed out waiting for NAT deletion (continuing)."
}

delete_vpc_endpoints_in_vpc() {
  local vpc_id="$1"
  log "AWS: delete VPC Endpoints in VPC ${vpc_id}"

  local eps
  eps="$(awsq ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)"

  if [[ -z "${eps}" ]]; then
    log "No VPC endpoints found."
    return 0
  fi

  log "Deleting VPC endpoints: ${eps}"
  awsq ec2 delete-vpc-endpoints --vpc-endpoint-ids ${eps} >/dev/null 2>&1 || true
}

detach_delete_igw() {
  local vpc_id="$1"
  log "AWS: detach/delete Internet Gateways (if any)"

  local igws
  igws="$(awsq ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)"

  if [[ -z "${igws}" ]]; then
    log "No IGW attached."
    return 0
  fi

  for igw in ${igws}; do
    log "Detaching IGW ${igw} from ${vpc_id}"
    awsq ec2 detach-internet-gateway --internet-gateway-id "${igw}" --vpc-id "${vpc_id}" >/dev/null 2>&1 || true
    log "Deleting IGW ${igw}"
    awsq ec2 delete-internet-gateway --internet-gateway-id "${igw}" >/dev/null 2>&1 || true
  done
}

delete_enis_in_vpc() {
  local vpc_id="$1"
  log "AWS: delete ENIs in VPC ${vpc_id} (best-effort; ELB/NAT can leave these behind)"

  # We try several passes; some ENIs only disappear after LBs/NAT are truly gone.
  local pass
  for pass in 1 2 3 4; do
    local enis
    enis="$(awsq ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null || true)"

    if [[ -z "${enis}" ]]; then
      log "No ENIs remain."
      return 0
    fi

    log "Pass ${pass}: found ENIs: ${enis}"
    for eni in ${enis}; do
      # Try detach if attached
      local att
      att="$(awsq ec2 describe-network-interfaces \
        --network-interface-ids "${eni}" \
        --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)"
      if [[ -n "${att}" && "${att}" != "None" && "${att}" != "null" ]]; then
        log "Detaching ENI ${eni} attachment ${att} (force)"
        awsq ec2 detach-network-interface --attachment-id "${att}" --force >/dev/null 2>&1 || true
      fi

      log "Deleting ENI ${eni}"
      awsq ec2 delete-network-interface --network-interface-id "${eni}" >/dev/null 2>&1 || true
    done

    sleep "${POLL_INTERVAL}"
  done

  warn "Some ENIs may still remain (continuing)."
}

delete_route_tables_non_main() {
  local vpc_id="$1"
  log "AWS: delete NON-MAIN route tables in VPC ${vpc_id}"

  local rts
  rts="$(awsq ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[?Associations[?Main==`false`]].RouteTableId' --output text 2>/dev/null || true)"

  if [[ -z "${rts}" ]]; then
    log "No non-main route tables found."
    return 0
  fi

  for rt in ${rts}; do
    # Disassociate all non-main associations
    local assoc_ids
    assoc_ids="$(awsq ec2 describe-route-tables \
      --route-table-ids "${rt}" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text 2>/dev/null || true)"

    if [[ -n "${assoc_ids}" ]]; then
      for assoc in ${assoc_ids}; do
        log "Disassociating route table assoc ${assoc} from ${rt}"
        awsq ec2 disassociate-route-table --association-id "${assoc}" >/dev/null 2>&1 || true
      done
    fi

    log "Deleting route table ${rt}"
    awsq ec2 delete-route-table --route-table-id "${rt}" >/dev/null 2>&1 || true
  done
}

delete_subnets() {
  local vpc_id="$1"
  log "AWS: delete subnets in VPC ${vpc_id}"

  local subs
  subs="$(awsq ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)"

  if [[ -z "${subs}" ]]; then
    log "No subnets found."
    return 0
  fi

  for sn in ${subs}; do
    log "Deleting subnet ${sn}"
    awsq ec2 delete-subnet --subnet-id "${sn}" >/dev/null 2>&1 || true
  done
}

delete_network_acls_non_default() {
  local vpc_id="$1"
  log "AWS: delete NON-DEFAULT network ACLs in VPC ${vpc_id}"

  local acls
  acls="$(awsq ec2 describe-network-acls \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'NetworkAcls[?IsDefault==`false`].NetworkAclId' --output text 2>/dev/null || true)"

  if [[ -z "${acls}" ]]; then
    log "No non-default NACLs found."
    return 0
  fi

  for acl in ${acls}; do
    log "Deleting NACL ${acl}"
    awsq ec2 delete-network-acl --network-acl-id "${acl}" >/dev/null 2>&1 || true
  done
}

delete_security_groups_non_default() {
  local vpc_id="$1"
  log "AWS: delete NON-DEFAULT security groups in VPC ${vpc_id}"

  local sgs
  sgs="$(awsq ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"

  if [[ -z "${sgs}" ]]; then
    log "No non-default SGs found."
    return 0
  fi

  for sg in ${sgs}; do
    log "Deleting SG ${sg}"
    awsq ec2 delete-security-group --group-id "${sg}" >/dev/null 2>&1 || true
  done
}

aws_dependency_cleanup() {
  local vpc_id="$1"

  log "AWS dependency cleanup starting for VPC: ${vpc_id}"
  log "This is the step that prevents VPC DependencyViolation loops."

  # Order matters
  delete_elbs_in_vpc "${vpc_id}"
  delete_target_groups_in_vpc "${vpc_id}"
  delete_nat_gateways_in_vpc "${vpc_id}"
  delete_vpc_endpoints_in_vpc "${vpc_id}"

  # After ELB/NAT deletion, ENIs often unblock
  delete_enis_in_vpc "${vpc_id}"

  # Networking objects
  detach_delete_igw "${vpc_id}"
  delete_route_tables_non_main "${vpc_id}"
  delete_subnets "${vpc_id}"
  delete_network_acls_non_default "${vpc_id}"
  delete_security_groups_non_default "${vpc_id}"

  log "AWS dependency cleanup done (best-effort)."
}

############################################
# Main flow
############################################
log "Region: ${AWS_REGION} | Cluster: ${EKS_CLUSTER_NAME}"
echo

# 1) Best-effort k8s cleanup (only helps if cluster still exists)
kube_best_effort_cleanup
echo

# 2) Terraform init/refresh so outputs exist
tf_init_refresh || true

# 3) Grab VPC ID early (useful for cleanup even if TF fails)
VPC_ID="$(get_vpc_id || true)"
if [[ -n "${VPC_ID}" ]]; then
  log "Detected VPC_ID: ${VPC_ID}"
else
  warn "Could not determine VPC_ID from terraform output/tags yet."
fi
echo

# 4) Try terraform destroy. If it fails with VPC dependency, clean AWS deps and retry.
if [[ -d "${TF_DIR}" ]]; then
  set +e
  tf_destroy
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "Terraform destroy failed (likely VPC DependencyViolation). Running AWS dependency cleanup then retrying."

    # Refresh outputs again (sometimes needed right before cleanup)
    tf_init_refresh || true
    VPC_ID="$(get_vpc_id || true)"

    if [[ -z "${VPC_ID}" ]]; then
      warn "Still cannot determine VPC_ID automatically."
      warn "Run: (cd ${TF_DIR_REL} && terraform output -raw vpc_id)  and export VPC_ID=<that> then re-run."
      die "No VPC_ID available to proceed safely."
    fi

    aws_dependency_cleanup "${VPC_ID}"
    echo

    log "Retry terraform destroy (attempt 2)"
    set +e
    tf_destroy
    rc2=$?
    set -e

    if [[ $rc2 -ne 0 ]]; then
      warn "Terraform destroy still failed. One more deep-clean pass + retry."

      aws_dependency_cleanup "${VPC_ID}"
      echo

      log "Retry terraform destroy (attempt 3)"
      tf_destroy || true
    fi
  fi
else
  warn "Terraform dir not found; skipping terraform destroy."
fi

echo
log "Final best-effort: if VPC still exists, attempt direct delete after cleanup"

# If VPC still exists, try deleting it directly (best-effort)
if [[ -z "${VPC_ID}" ]]; then
  VPC_ID="$(get_vpc_id || true)"
fi

if [[ -n "${VPC_ID}" ]]; then
  # Check if VPC exists
  exists="$(awsq ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  if [[ -n "${exists}" && "${exists}" != "None" && "${exists}" != "null" ]]; then
    warn "VPC ${VPC_ID} still exists. Running cleanup + direct delete-vpc."
    aws_dependency_cleanup "${VPC_ID}"
    awsq ec2 delete-vpc --vpc-id "${VPC_ID}" >/dev/null 2>&1 || true
  else
    log "VPC already gone."
  fi
else
  warn "No VPC_ID available for final direct-delete check."
fi

echo
log "Done."
log "If you’re still incurring cost, the usual culprits are: NAT Gateway, NLB, and leftover ENIs."
log "This script targets all three with waits."

