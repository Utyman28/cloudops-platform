# Terraform (dev) — AWS VPC + EKS Environment

This folder wires together the reusable Terraform modules to provision a **dev** environment in **AWS ca-central-1** for the CloudOps Platform demo.

It creates:
- A dedicated **VPC** (public/private subnets, routing)
- An **Amazon EKS** cluster
- A managed **node group** for workloads
- Supporting IAM/security resources required by EKS

> This environment is designed to be **reproducible** (apply/destroy) and cost-controlled for demos.

---

## Prerequisites

- Terraform installed
- AWS CLI configured (credentials + default region or explicit region)
- Permissions to create: VPC, EKS, IAM, EC2, CloudWatch, and related resources

Recommended:
```bash
aws configure
aws sts get-caller-identity

## Quick start (apply)
```bash
cd terraform/environments/dev
terraform init -input=false
terraform plan
terraform apply -auto-approve

After apply, update kubeconfig (used by the demo scripts):
```bash
aws eks update-kubeconfig --region ca-central-1 --name cloudops-dev-eks
kubectl get nodes

## Outputs
Typical outputs I may use during validation:
EKS cluster name / endpoint
VPC and subnet IDs
Node group details

(Outputs are defined in this environment’s Terraform configuration.)

## Cost control
EKS and its node group are the primary cost drivers for this project.After a session or a demo,I destroy the environment:
```bash
terraform destroy -auto-approve

## Troubleshooting
kubectl cannot connect after terraform apply
```bash
aws eks update-kubeconfig --region ca-central-1 --name cloudops-dev-eks
kubectl get nodes

## Terraform destroy seems stuck
-Common causes:
-Kubernetes LoadBalancer resources still exist (NLB deletion in progress)
-VPC ENIs still attached for a few minutes after LB deletion

Fix:
-Uninstall ingress-nginx / delete LoadBalancer services first
-Wait a few minutes and retry terraform destroy


