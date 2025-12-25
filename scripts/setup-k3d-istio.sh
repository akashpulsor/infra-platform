#!/bin/bash
# k3d + Istio Setup Script for Windows (Git Bash)
# Run this script to set up or restore the cluster

set -e

echo "=== k3d + Istio Local Development Setup ==="

# Check if cluster exists
if k3d cluster list | grep -q "cc-local"; then
    echo "Cluster 'cc-local' exists. Starting it..."
    k3d cluster start cc-local
else
    echo "Creating new cluster 'cc-local'..."
    k3d cluster create cc-local \
        --servers 1 \
        --agents 2 \
        -p "8081:80@loadbalancer" \
        -p "8443:443@loadbalancer" \
        --k3s-arg "--disable=traefik@server:0"
fi

echo "Waiting for nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Check if Istio is installed
if ! kubectl get namespace istio-system &>/dev/null; then
    echo "Installing Istio..."
    istioctl install --set profile=default -y
    
    echo "Creating apps namespace..."
    kubectl create namespace apps
    kubectl label namespace apps istio-injection=enabled
    
    echo "Deploying nginx test app..."
    kubectl apply -n apps -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF

    echo "Creating Istio Gateway..."
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: central-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
EOF

    echo "Creating VirtualService..."
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: nginx
  namespace: apps
spec:
  hosts:
  - "nginx.localhost"
  - "auth.localhost"
  gateways:
  - istio-system/central-gateway
  http:
  - route:
    - destination:
        host: nginx.apps.svc.cluster.local
        port:
          number: 80
EOF

    echo "Waiting for pods..."
    kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=180s
    kubectl wait --for=condition=Ready pods --all -n apps --timeout=180s
else
    echo "Istio already installed. Waiting for pods..."
    kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=180s
    kubectl wait --for=condition=Ready pods --all -n apps --timeout=180s
fi

echo "Configuring k3d serverlb..."
NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
echo "NodePort: $NODEPORT"

MSYS_NO_PATHCONV=1 docker exec k3d-cc-local-serverlb sh -c "cat > /etc/nginx/nginx.conf << NGINX
error_log stderr notice;
worker_processes auto;
events {
  multi_accept on;
  use epoll;
  worker_connections 1024;
}
stream {
  upstream 80_tcp {
    server k3d-cc-local-agent-0:$NODEPORT max_fails=1 fail_timeout=10s;
    server k3d-cc-local-agent-1:$NODEPORT max_fails=1 fail_timeout=10s;
    server k3d-cc-local-server-0:$NODEPORT max_fails=1 fail_timeout=10s;
  }
  server {
    listen 80;
    proxy_pass 80_tcp;
    proxy_timeout 600;
    proxy_connect_timeout 2s;
  }
  upstream 6443_tcp {
    server k3d-cc-local-server-0:6443 max_fails=1 fail_timeout=10s;
  }
  server {
    listen 6443;
    proxy_pass 6443_tcp;
    proxy_timeout 600;
    proxy_connect_timeout 2s;
  }
}
NGINX"

docker exec k3d-cc-local-serverlb nginx -s reload

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Test with:"
echo "  curl -H \"Host: nginx.localhost\" http://localhost:8081"
echo ""

# Test
echo "Testing connection..."
if curl -s -H "Host: nginx.localhost" http://localhost:8081 | grep -q "Welcome to nginx"; then
    echo "✓ Success! Nginx is responding."
else
    echo "✗ Test failed. Check troubleshooting in documentation."
fi

# Test
echo "deploying  observality..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/kiali.yaml

kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/prometheus.yaml

kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/grafana.yaml

kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/jaeger.yaml


#kubectl create ns auth

#helm install keycloak ~/workspace/infra-platform/charts/keycloak -n auth --force