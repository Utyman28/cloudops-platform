# Ingress (NGINX) + TLS Termination on AWS NLB (ACM)

Expose a Kubernetes Service via **NGINX Ingress** while terminating **TLS at an AWS Network Load Balancer (NLB)** using an **ACM certificate**.

This module publishes the `apps/hpa-demo` service and supports:
- **External HTTP** access (port **80**)
- **External HTTPS** access (port **443**) with **TLS termination at the NLB (ACM)**
- **In-cluster routing** from NGINX → Service over HTTP (port **80**)

---

## Cost control checklist

Before you finish the session, confirm the items below to avoid surprise charges:
- [ ] Delete the **Ingress** (`kubectl delete -f ...`)
- [ ] Uninstall **ingress-nginx** (`helm uninstall ...`)
- [ ] Confirm the **LoadBalancer Service** is gone (NLB deletion follows)
- [ ] If you’re done with the environment: scale down / delete EKS node group (or cluster) per your project plan

> NLB + EKS are the typical cost drivers. Don’t leave them running unintentionally.

---

## Architecture

Traffic flow:

- Client → Route 53 (`app.utieyincloud.com`) → **AWS NLB** (TLS 443 / TCP 80)
- TLS terminates at the **NLB** (ACM certificate)
- NLB forwards traffic to the **ingress-nginx controller Service**
- NGINX routes to `hpa-demo` Service in the `apps` namespace

### Evidence (screenshots)

**1) External HTTPS (TLS terminates at NLB / ACM)**  
![External HTTPS](../../docs/images/ingress/01-external-https.png)

**2) External HTTP**  
![External HTTP](../../docs/images/ingress/02-external-http.png)

**3) In-cluster routing**  
![In-cluster routing](../../docs/images/ingress/03-in-cluster-routing.png)

---

## Repository files

- `k8s/ingress/ingress-nginx-values.yaml` — Helm values for ingress-nginx (NLB + ACM TLS termination config)
- `k8s/ingress/hpa-demo-ingress.yaml` — Ingress resource for `app.utieyincloud.com`

---

## Deploy

### 1) Install ingress-nginx with Helm
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/ingress-nginx-values.yaml

