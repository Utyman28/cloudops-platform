# Design Rationale – CloudOps Platform

This document explains **why** specific architectural and operational decisions
were made in this project. The goal is to demonstrate production-level reasoning,
not just implementation.

---

## 1. Platform Goals

This platform was designed to:
- Be **reproducible** (full rebuild via Terraform + scripts)
- Mirror **real production constraints**
- Optimize for **simplicity, cost awareness, and operational clarity**
- Demonstrate **validated behavior**, not theoretical setups

---

## 2. Why EKS + Terraform

**Terraform**
- Enables deterministic, repeatable infrastructure provisioning
- Separates environment wiring from reusable modules
- Reflects real-world GitOps / IaC practices

**Amazon EKS**
- Managed control plane reduces operational overhead
- Industry-standard Kubernetes platform
- Enables realistic autoscaling and ingress behavior

---

## 3. Ingress Design Choice: NLB + NGINX (L4 First)

### Chosen Architecture
Client
→ Route53
→ AWS NLB (TLS termination via ACM)
→ NGINX Ingress Controller
→ Kubernetes Service
→ Application Pods


### Why NLB instead of ALB (initially)
- Lower cost and simpler pricing model
- Higher performance at L4
- Fewer moving parts for a baseline production setup
- Common pattern for platform teams standardizing ingress

### Why TLS terminates at the NLB
- Offloads TLS from the cluster
- Uses AWS ACM-managed certificates
- Simplifies ingress configuration
- Matches common enterprise security posture

---

## 4. Intentional Security Posture

- **No public HTTP listener**
- Only port **443** exposed on the NLB
- No HTTP → HTTPS redirects handled at ingress level
- HTTP traffic times out by design

This enforces encryption by default and avoids accidental plaintext exposure.

---

## 5. Autoscaling (HPA) Validation Philosophy

Autoscaling was not assumed — it was **proven**.

- CPU-bound workload deployed intentionally
- Metrics Server installed and patched for EKS
- Load generator used to exceed CPU thresholds
- Scale-up, stabilization, and scale-down observed live
- Evidence captured via screenshots and events

This mirrors how autoscaling is validated in real production environments.

---

## 6. Rebuild & Teardown Discipline

Production platforms must be:
- Easy to rebuild
- Safe to tear down
- Cost-aware by default

This project includes:
- One-command rebuild scripts
- Explicit teardown steps
- No orphaned cloud resources

This reflects operational hygiene expected of senior engineers.

---

## 7. Future Extensions (Documented, Not Implemented)

- ALB-based ingress (L7 routing)
- WAF integration
- Observability stack (Prometheus / Grafana)
- GitOps deployment flow

These were intentionally left out to keep the demo focused and auditable.

