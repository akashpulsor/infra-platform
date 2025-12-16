#!/bin/bash
set -euo pipefail

# ==============================================================================
# ⚠️ Configuration Variables - CHANGE THESE FOR YOUR ENVIRONMENT ⚠️
# ==============================================================================

# The Kubernetes Namespace where Keycloak will be installed
export NAMESPACE="auth-system"

# The desired host/domain for Keycloak access (e.g., auth.yourcompany.com)
export KEYCLOAK_HOST="auth.dev.example.com"

# The Name/Namespace of your Platform Gateway (e.g., front-dev/platform-ui-gateway)
export PLATFORM_GATEWAY_REF="front-dev/platform-ui-gateway"

# Helm Chart details
export KEYCLOAK_RELEASE="keycloak-prod"
export KEYCLOAK_CHART_REPO="bitnami"
export KEYCLOAK_CHART_NAME="keycloak"
export KEYCLOAK_SVC_NAME="keycloak"

# ==============================================================================
# --- Dependency and Setup ---
# ==============================================================================

echo "--- 1. Setting up namespace and deploying Keycloak application ---"

# Create Namespace and enable Istio sidecar injection
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

# Add Helm Repository and deploy Keycloak
helm repo add "$KEYCLOAK_CHART_REPO" https://charts.bitnami.com/bitnami > /dev/null
helm repo update > /dev/null

# Install/Upgrade Keycloak with proxy forwarding enabled (Fix #1: App Setup)
helm upgrade --install "$KEYCLOAK_RELEASE" "$KEYCLOAK_CHART_REPO/$KEYCLOAK_CHART_NAME" \
  --namespace "$NAMESPACE" \
  --set auth.adminUser=admin \
  --set auth.adminPassword=password \
  --set ingress.enabled=false \
  --set service.type=ClusterIP \
  --set extraEnv[0].name=PROXY_ADDRESS_FORWARDING \
  --set extraEnv[0].value=true \
  --wait

echo "Keycloak deployment complete. Waiting for mesh readiness..."
sleep 15

# ==============================================================================
# --- Istio Configuration Fixes (The Debugged Solution) ---
# ==============================================================================

echo "--- 2. Configuring Istio Gateway Host Entry (Fix #2) ---"

# Split Gateway reference for patching
GATEWAY_NAMESPACE=$(echo "$PLATFORM_GATEWAY_REF" | cut -d/ -f1)
GATEWAY_NAME=$(echo "$PLATFORM_GATEWAY_REF" | cut -d/ -f2)

# Patch the Gateway to accept the new host entry
kubectl patch gateway -n "$GATEWAY_NAMESPACE" "$GATEWAY_NAME" --type='json' -p='
[
  {"op": "add", "path": "/spec/servers/0/hosts/-", "value": "'"$KEYCLOAK_HOST"'"}
]
' || {
  echo "Warning: Host already exists or Gateway patching failed."
}

echo "--- 3. Applying Declarative Istio VirtualService Policy (Fix #3 & #4) ---"

# 3a. Apply the HTTP-to-HTTPS redirect rule (Fix #4: Solved 400/404 errors)
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ${KEYCLOAK_SVC_NAME}-redirect
  namespace: ${NAMESPACE}
spec:
  # Fix #3: Explicitly define the Gateway namespace (Critical for routing)
  gateways:
  - ${PLATFORM_GATEWAY_REF}
  hosts:
  - ${KEYCLOAK_HOST}
  http:
  - match:
    - uri:
        prefix: /
    redirect:
      scheme: https
      authority: ${KEYCLOAK_HOST}
      redirectCode: 301 
EOF

# 3b. Apply the secure routing rule for HTTPS traffic
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ${KEYCLOAK_SVC_NAME}-secure
  namespace: ${NAMESPACE}
spec:
  gateways:
  - ${PLATFORM_GATEWAY_REF}
  hosts:
  - ${KEYCLOAK_HOST}
  http:
  - route:
    - destination:
        host: ${KEYCLOAK_SVC_NAME}.${NAMESPACE}.svc.cluster.local
        port:
          number: 8080
EOF

# ==============================================================================
# --- Final Output ---
# ==============================================================================

echo "--- Deployment Success ---"
echo "Keycloak is deployed, and all HTTP traffic to $KEYCLOAK_HOST will now redirect to HTTPS."
echo "Access Host: $KEYCLOAK_HOST"
echo "Admin User: admin | Admin Password: password (Update securely after first login!)"