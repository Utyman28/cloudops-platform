echo "=== Kube context ==="
kubectl config current-context

echo "=== Nodes ==="
kubectl get nodes -o wide

echo "=== Ingress NGINX LB (should be NLB hostname + 443) ==="
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide

echo "=== App ingress routing ==="
kubectl -n apps get ingress hpa-demo -o wide
kubectl -n apps describe ingress hpa-demo | sed -n '1,120p'

echo "=== HTTPS should be 200 ==="
curl -Ik https://app.utieyincloud.com

echo "=== HTTP should NOT be your primary path (timeout or redirect is acceptable depending on exposure) ==="
curl -I --max-time 5 http://app.utieyincloud.com ; echo "exit=$?"

