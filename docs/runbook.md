# CloudOps Platform Runbook (Demo + Validation + Teardown)

This runbook is the operator guide for rebuilding, validating, presenting, and tearing down the CloudOps Platform demo safely.

## What this environment proves
- Modular Terraform provisioning for AWS VPC + EKS
- Ingress via NGINX behind AWS NLB with TLS (ACM) and HTTPS-only enforcement
- HPA autoscaling under real CPU load (metrics-server gate + evidence)
- Observability: Prometheus scrape + Grafana views for ingress traffic
- Cost discipline: teardown prevents orphaned NLB, NAT gateways, and ENIs

---

## Prerequisites

### Required CLI tools
- aws
- kubectl
- helm
- terraform
- jq
- dig
- curl

### AWS and Kubernetes
- AWS credentials configured locally (or via assumed role)
- Access to the EKS cluster defined by `EKS_CLUSTER_NAME` in `AWS_REGION`

---

## Environment variables (optional overrides)

### Core
- `AWS_REGION` (default: `ca-central-1`)
- `EKS_CLUSTER_NAME` (default: `cloudops-dev-eks`)

### Route53 (optional)
Used only to create or update the DNS record for the demo:
- `ROUTE53_ZONE_ID` (accepts `ZXXXX` or `/hostedzone/ZXXXX`)
- `ROUTE53_RECORD_NAME` (example: `app.utieyincloud.com`)

### Application
- `APP_NS` (default: `apps`)
- `APP_HOST` (default: `app.utieyincloud.com`)
- `APP_INGRESS_NAME` (default: `hpa-demo`)
- `APP_POD_SELECTOR` (default: `app=hpa-demo`)

### Validation timing
- `OBS_WINDOW_SECONDS` (default: `120`)
- `OBS_INTERVAL_SECONDS` (default: `5`)

---

## Demo lifecycle (recommended order)

### Step 1: Rebuild the environment  
**Terraform + NGINX Ingress + Application**

Command:
```bash
./scripts/rebuild-demo.sh
```

What this step does:
- Runs `terraform apply` in `terraform/environments/dev`
- Configures kubeconfig for the EKS cluster
- Installs or upgrades ingress-nginx using an AWS NLB with ACM TLS
- Enforces HTTPS-only external access
- Deploys the demo application manifests
- Optionally updates Route53 DNS (if configured)
- Performs proof checks for HTTPS success and HTTP failure

Expected outcomes:
- An AWS NLB hostname is printed
- The application Ingress has an external address
- HTTPS returns HTTP 200
- HTTP access fails or times out (expected)

---

### Step 2: Validate the environment (evidence-oriented)

Command:
```bash
./scripts/validate-env.sh
```

What this step validates:
- Kubernetes context and node health
- Ingress controller Service and NLB hostname
- Metrics API availability (required for HPA)
- HTTPS access (DNS optional via `--resolve`)
- HTTP negative test (should not be the primary path)
- HPA behavior observed over time (non-brittle reporting)

Expected outcomes:
- HTTPS returns HTTP 200
- Metrics API is Available or a warning is reported
- HPA status shows replica counts and scaling decisions

---

### Step 3: Teardown (cost control discipline)

Command:
```bash
./scripts/teardown.sh
```

What this step does:
- Best-effort Kubernetes cleanup (apps and ingress first)
- Attempts `terraform destroy`
- If dependency violations occur:
  - Detects VPC ID
  - Removes NLBs, target groups, NAT gateways, ENIs, and other blockers
  - Retries `terraform destroy`
- Final best-effort cleanup to prevent orphaned AWS resources

Expected outcomes:
- Terraform state destroyed cleanly
- No orphaned NLBs, NAT gateways, or ENIs
- AWS account left in a cost-neutral state

---

## Common issues and recovery

### Terraform destroy fails with DependencyViolation
Cause:
- NLB, NAT gateway, or ENIs still exist

Resolution:
```bash
./scripts/teardown.sh
```
The script performs deep cleanup and retries automatically.

### HPA shows `<unknown>` metrics
Cause:
- Metrics Server not ready or Metrics API unavailable

Resolution:
```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
kubectl -n apps top pods
```

