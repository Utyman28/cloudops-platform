# Sprint 1 — Rebuild/Validate/Teardown Proof (3 Cycles)

**Goal:** Prove `rebuild-demo.sh`, `validate-env.sh`, and `teardown.sh` are reliable and repeatable, with no leftover cost drivers.

**Region:** ca-central-1  
**Cluster:** cloudops-dev-eks  
**Date:** YYYY-MM-DD  
**Operator:** Utieyin

## Pass Criteria (per cycle)
- [ ] Rebuild completes successfully
- [ ] Validation passes (or known acceptable warnings documented)
- [ ] Teardown completes successfully (no stuck waits)
- [ ] Post-teardown checks show no active cost drivers (NLB/NAT/leftover ENIs)

## Cost-driver checks (run after each teardown)
Commands:
```bash
aws elbv2 describe-load-balancers --region ca-central-1 \
  --query "LoadBalancers[?contains(LoadBalancerName, 'cloudops')].[LoadBalancerName,State.Code]" --output table || true

aws ec2 describe-nat-gateways --region ca-central-1 \
  --filter Name=state,Values=available,pending \
  --query "NatGateways[].NatGatewayId" --output table || true

aws ec2 describe-network-interfaces --region ca-central-1 \
  --filters Name=tag:Project,Values=cloudops-eks Name=status,Values=in-use \
  --query "NetworkInterfaces[].NetworkInterfaceId" --output table || true

## Cost Control Verification

After teardown, the following checks were performed to ensure zero ongoing cost:

- EKS clusters: none
- Load balancers (NLB/ALB): none
- NAT Gateways: deleted
- ENIs: none in-use
- Unattached EBS volumes: none

AWS Cost Explorer confirms no ongoing infrastructure charges.

