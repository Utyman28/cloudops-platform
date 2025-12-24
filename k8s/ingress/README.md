# Ingress (NGINX) with TLS Termination on AWS NLB (ACM)

This module exposes a Kubernetes Service via **NGINX Ingress** while terminating **TLS at an AWS Network Load Balancer (NLB)** using an **ACM certificate**.

The design intentionally uses **NLB (Layer 4)** instead of ALB to demonstrate a clean separation of concerns between:
- **Cloud networking / TLS termination**
- **Kubernetes ingress routing**

---

## What this module demonstrates

- External access to Kubernetes workloads using **NGINX Ingress**
- **TLS termination at AWS NLB** using ACM (no certs stored in cluster)
- Clear understanding of **L4 vs L7 responsibilities**
- In-cluster routing over **plain HTTP** after TLS is terminated
- Cost-aware lifecycle management (install, validate, teardown)

This mirrors real production patterns used in AWS-hosted Kubernetes platforms.

---

## Architecture

### High-level traffic flow

Client
↓
Route 53 (app.utieyincloud.com)
↓
AWS Network Load Balancer (TCP 443)
↓ (TLS terminates at NLB using ACM)
NGINX Ingress Controller (EKS)
↓
Kubernetes Service
↓
Application Pods (hpa-demo

### Why NLB (and not ALB)?

- **NLB (Layer 4)** is responsible only for transport and TLS
- **NGINX Ingress (Layer 7)** handles HTTP routing and Kubernetes semantics
- No dependency on AWS-specific Ingress controllers
- Avoids mixing cloud-native L7 logic with Kubernetes routing
- Easier to reason about, debug, and operate

> An ALB-based design is valid, but intentionally **out of scope** for this project.
> This repo demonstrates depth with NLB first, not breadth.

---

## External behavior (validated)

### Evidence (screenshots)

**1) External HTTPS (TLS terminates at NLB / ACM)**  
![External HTTPS](../../docs/images/ingress/01-external-https.png)

**2) External HTTP**  
![External HTTP](../../docs/images/ingress/02-external-http.png)

**3) In-cluster routing (NGINX → Service → Pods)**  
![In-cluster routing](../../docs/images/ingress/03-in-cluster-routing.png)

> HTTPS is the primary access path.  
> HTTP visibility is intentional for demonstration and can be restricted further in production.

---

## Kubernetes resources

- `ingress-nginx` installed via Helm
- Service type: `LoadBalancer` (AWS NLB)
- TLS handled entirely by AWS (ACM)
- NGINX forwards traffic internally over HTTP

### Files

- `k8s/ingress/ingress-nginx-values.yaml`  
  Helm values configuring NLB + ACM TLS termination

- `k8s/apps/hpa-demo-ingress.yaml`  
  Ingress resource routing `app.utieyincloud.com` to the `hpa-demo` Service

---

## Deployment

### Install ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/ingress-nginx-values.yaml

### Apply application ingress
```bash
kubectl apply -f k8s/apps/hpa-demo-ingress.yaml

### Validation
```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl -n apps get ingress hpa-demo

curl -Ik https://app.utieyincloud.com

Expected:
NLB hostname assigned
HTTPS returns 200 OK
Traffic routes correctly through NGINX to pods

## Cost control & teardown

To avoid surprise AWS charges:
```bash
kubectl delete -f k8s/apps/hpa-demo-ingress.yaml
helm uninstall ingress-nginx -n ingress-nginx
This triggers deletion of the AWS NLB. 

Scale down or delete the EKS node group.
Or run terraform destroy from terraform/environments/dev

## Why this matters

This ingress design demonstrates:
Clear understanding of AWS networking primitives
Correct TLS boundary placement
Kubernetes-native routing practices
Operational discipline (validation + teardown)

