# Terraform Environment: dev

This folder provisions the **dev** AWS infrastructure for the CloudOps Platform using Terraform.

It wires together reusable modules (VPC + EKS) and produces outputs needed to operate the cluster (kubectl access, cluster endpoint, etc.).

## What this environment provisions

- **VPC** (networking baseline)
  - Private subnets for worker nodes
  - Security groups and routing appropriate for EKS
- **EKS cluster**
  - Control plane + worker node group(s)
  - IAM roles and permissions required for cluster operation

> Note: Kubernetes add-ons and workloads (HPA demo, ingress-nginx, Ingress resources) live under `/k8s`.

## How to use

From this directory:

### 1) Initialize
```bash
terraform init

### 2) Plan
```bash
terraform plan

### 3) Apply
```bash
terraform apply

### 4) Configure kubectl (example)
```bash
aws eks update-kubeconfig --region ca-central-1 --name <cluster_name>
kubectl get nodes

Tear down (cost control)
```bash
terraform destroy

Outputs
See outputs.tf for values exposed by this environment (cluster name, endpoint, etc.).

