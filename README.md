# CloudOps Platform

A production-grade **Cloud & DevOps platform** built on **AWS**, using **Terraform** for infrastructure provisioning and **Kubernetes (EKS)** for application orchestration.

This repository demonstrates **real-world infrastructure automation**, **Kubernetes operations**, and **validated scaling behavior** under load — with full teardown and cost-control discipline.

---

## What this project proves 

This project demonstrates the ability to:

- Design and provision AWS infrastructure using **modular Terraform**
- Operate a production-style **Amazon EKS** cluster
- Expose applications securely using **NGINX Ingress + AWS NLB**
- Validate **Horizontal Pod Autoscaler (HPA)** behavior under real load
- Reason about **failure scenarios, observability, and cost control**
- Rebuild and tear down environments safely and repeatably

This mirrors how Cloud / DevOps engineers work in real production environments.

---

## Architecture Overview

## Live Demo (5 minutes)

To demo this project live, I rebuild the environment with Terraform (VPC + EKS), deploy the Kubernetes workloads (HPA demo + ingress-nginx), and then prove behavior with real evidence: (1) autoscaling—start a CPU load generator and watch `kubectl get hpa,pods -w` scale from 1→5 and then back down after load stops, and (2) external access—verify DNS → NLB (ACM TLS termination) → NGINX Ingress → Service → Pods by curling `https://app.utieyincloud.com` and confirming `200 OK`. After the demo, I tear everything down (Ingress deleted, ingress-nginx uninstalled, and EKS/nodegroup removed) to prevent AWS charges.


## Architecture diagrams

- Ingress (NLB + ACM TLS → NGINX Ingress → Service → Pods): [`docs/architecture`](./docs/architecture/)

## Modules

- Kubernetes HPA autoscaling proof: see screenshots in `docs/images/hpa`
- Ingress (NGINX) + TLS termination at NLB (ACM): [`k8s/ingress`](./k8s/ingress/)
- Terraform environment wiring (dev): [`terraform/environments/dev`](./terraform/environments/dev/)

### Core technologies

- **Cloud**: AWS
- **Infrastructure as Code**: Terraform (modular VPC + EKS)
- **Container Orchestration**: Amazon EKS
- **Ingress & Traffic Management**: NGINX Ingress Controller
- **Autoscaling**: Horizontal Pod Autoscaler (HPA)
- **Observability**: Metrics Server

---

## High-level traffic flow (Ingress)

Client
↓
Route 53 (app.utieyincloud.com)
↓
AWS Network Load Balancer (TLS 443 / HTTP 80)
↓ (TLS terminates at NLB via ACM)
NGINX Ingress Controller (EKS)
↓
Kubernetes Service
↓
Application Pod


Ingress is documented in detail here:  
  `k8s/ingress/README.md`

---

## Kubernetes HPA Autoscaling Proof

This section demonstrates **real, observed Horizontal Pod Autoscaling behavior** on a live Amazon EKS cluster.

Autoscaling behavior was **intentionally triggered, observed, and validated**

---

### What was implemented

- Deployed a CPU-bound application (`hpa-demo`)
- Configured **CPU requests and limits** correctly
- Installed and patched **Metrics Server** for EKS compatibility
- Created an **HPA** with:
  - Minimum replicas: `1`
  - Maximum replicas: `5`
  - Target CPU utilization: `50%`
- Generated sustained CPU load using a BusyBox-based load generator
- Observed **scale-up, stabilization, and scale-down** in real time

---

### Scale-Up Evidence

- CPU utilization exceeded the 50% threshold
- HPA increased replicas from **1 → 5**
- New pods were scheduled and reached `Running` state

Picture Evidence:
- `docs/images/hpa/01-hpa-scale-up.png`
- `docs/images/hpa/02-hpa-metrics.png`

---

### Stabilization Phase

- CPU remained consistently high
- Replica count stabilized at the maximum configured value

Picture Evidence:
- `docs/images/hpa/03-hpa-stabilization.png`

---

### Scale-Down Evidence

- Load generator was stopped
- CPU utilization dropped below target
- HPA gradually reduced replicas from **5 → 1**
- Pods were terminated **gracefully**, without disruption

Picture Evidence:
- `docs/images/hpa/04-hpa-scale-down-start.png`
- `docs/images/hpa/05-hpa-scale-down-cpu.png`
- `docs/images/hpa/08-hpa-scale-down-live.png`
- `docs/images/hpa/10-hpa-scale-down-complete.png`

---

### Final State

- Cluster returned to minimum replica count
- No pod crashes or instability observed
- HPA events confirm correct autoscaling decisions

Picture Evidence:
- `docs/images/hpa/11-hpa-final-event-trail.png`

---

## Why this matters

This implementation validates **how Kubernetes autoscaling behaves in production**, not just in theory.

It demonstrates:

- Correct sizing of CPU requests and limits
- Proper Metrics Server configuration on Amazon EKS
- Autoscaling decisions made dynamically by Kubernetes
- Safe and predictable scale-down behavior without service disruption

This pattern closely mirrors how autoscaling is **tested, verified, and trusted** in real production Kubernetes platforms.

---

## Infrastructure provisioning (Terraform)

All AWS infrastructure is provisioned using Terraform with a clear separation of concerns:

- **Reusable modules**: `terraform/modules/`
  - VPC
  - EKS
- **Environment wiring**: `terraform/environments/dev/`

Terraform environment documentation:  
 `terraform/environments/dev/README.md`

---

## Cost control & teardown discipline

This project was designed with **cost awareness** in mind.

Before ending any session:

- Ingress resources are deleted
- ingress-nginx is uninstalled (triggering NLB deletion)
- EKS node groups and clusters are scaled down or destroyed
- Terraform state is cleanly destroyed when finished

This reflects **real operational hygiene** expected in production cloud environments.

---

## Rebuild / Live Demo Capability

This environment can be fully rebuilt and demonstrated live:

1. Provision infrastructure with Terraform
2. Deploy ingress controller and application
3. Validate external access (HTTP / HTTPS)
4. Trigger HPA scale-up and scale-down
5. Tear everything down safely

This ensures the project is **reproducible**, not a one-off setup.

---

## Status

- Architecture validated  
- Autoscaling behavior proven  
- External access secured via Ingress  
- Cost-control teardown verified  

This repository represents a **production-style Cloud & DevOps platform**.

