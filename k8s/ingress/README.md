# Ingress (NGINX) + TLS Termination on AWS NLB (ACM)

This module exposes the `apps/hpa-demo` service via NGINX Ingress and provides:
- External HTTP access (port 80)
- External HTTPS access (port 443) with TLS termination on the AWS Network Load Balancer using ACM
- In-cluster routing from NGINX -> service over HTTP (port 80)

## Architecture

- Client -> Route 53 (`app.utieyincloud.com`) -> AWS NLB (TLS 443 / TCP 80)
- TLS terminates at NLB (ACM certificate)
- NLB forwards to NGINX Ingress Controller Service
- NGINX routes to `hpa-demo` service in `apps` namespace

### Evidence (screenshots)

**1) External HTTPS (TLS terminates at NLB / ACM)**
![External HTTPS](../../docs/images/ingress/01-external-https.png)

**2) External HTTP**
![External HTTP](../../docs/images/ingress/02-external-http.png)

**3) In-cluster routing**
![In-cluster routing](../../docs/images/ingress/03-in-cluster-routing.png)

## Files

- `k8s/ingress/ingress-nginx-values.yaml` — Helm values overriding the ingress-nginx chart
- `k8s/ingress/hpa-demo-ingress.yaml` — Ingress resource for `app.utieyincloud.com`

## Deploy

### 1) Install ingress-nginx with Helm
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f k8s/ingress/ingress-nginx-values.yaml

