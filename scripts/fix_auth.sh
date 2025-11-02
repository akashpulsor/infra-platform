#!/bin/bash
set -e

###########################################################
# 🔧 CONFIGURATION
###########################################################

# 👉 Adjust as per your environment:
NAMESPACE="auth-system"                         # 🧩 Dedicated namespace for Keycloak
REALM="dalai-llama"                             # Realm name (multi-tenant or environment scope)
KEYCLOAK_RELEASE="keycloak"                     # Helm release name
KEYCLOAK_HOST="auth.dev.localhost"              # Public host for Keycloak
ADMIN_USER="admin"                              # Default admin user (required for deployment)
ADMIN_PASS="admin123"                           # Default admin password (required for deployment)

# Related app hosts (used for Gateway patch)
PLATFORM_UI_HOST="platform-ui.dev.localhost"
ADMIN_DASHBOARD_HOST="admin-dashboard.dev.localhost"

# New directory for Helm charts (e.g., 'infra-charts')
NEW_CHART_DIR="../charts" 

###########################################################
# 📂 STEP 1 — Directory Structure Management
###########################################################

# Check if the desired new directory exists, if not, create it.
echo "📂 Ensuring directory structure is in place..."
mkdir -p "${NEW_CHART_DIR}/keycloak/templates"

# Check if the old charts directory exists and move its contents if needed.
if [ -d "charts/keycloak" ]; then
    echo "📦 Moving existing charts/keycloak to ${NEW_CHART_DIR}/keycloak..."
    # Copy contents, preserving structure, then remove the old directory
    cp -r charts/keycloak/* "${NEW_CHART_DIR}/keycloak/"
    rm -rf charts/keycloak
fi

CHART_PATH="${NEW_CHART_DIR}/keycloak"

###########################################################
# 🧱 STEP 2 — Namespace & Chart File Generation
###########################################################
echo "🚀 Creating namespace ${NAMESPACE} (if missing)..."
kubectl get ns ${NAMESPACE} >/dev/null 2>&1 || kubectl create ns ${NAMESPACE}

echo "📦 Generating Keycloak Helm chart files in ${CHART_PATH}..."

cat <<EOF > ${CHART_PATH}/Chart.yaml
apiVersion: v2
name: keycloak
description: Self-hosted Keycloak for development & testing
version: 0.2.0
appVersion: "26.0"
EOF

cat <<EOF > ${CHART_PATH}/values.yaml
auth:
  adminUser: ${ADMIN_USER}
  adminPassword: ${ADMIN_PASS}

service:
  type: ClusterIP
  port: 8080

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

istio:
  host: ${KEYCLOAK_HOST}
  gatewayName: platform-ui-gateway
EOF

# --- Keycloak Deployment
cat <<EOF > ${CHART_PATH}/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.0
          args: ["start-dev"]
          env:
            - name: KEYCLOAK_ADMIN
              value: "${ADMIN_USER}"
            - name: KEYCLOAK_ADMIN_PASSWORD
              value: "${ADMIN_PASS}"
            - name: KC_PROXY
              value: "edge"
            - name: KC_HOSTNAME
              value: "${KEYCLOAK_HOST}"
          ports:
            - name: http
              containerPort: 8080
EOF

# --- Kubernetes Service
cat <<EOF > ${CHART_PATH}/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  selector:
    app: keycloak
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  type: ClusterIP
EOF

# --- Istio Virtual Service (FIX: Path Match)
cat <<EOF > ${CHART_PATH}/templates/virtualservice.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  hosts:
    - ${KEYCLOAK_HOST}
  gateways:
    - platform-ui-gateway
  http:
    - match:
        - uri:
            prefix: / # Crucial fix: Routes all paths, including /auth/ to Keycloak
      route:
        - destination:
            host: keycloak.${NAMESPACE}.svc.cluster.local
            port:
             number: 8080
EOF

###########################################################
# 🌐 STEP 3 — Ensure Istio Gateway Handles All Hosts (AUTOMATIC FIX)
###########################################################
echo "🔄 Patching Istio Gateway to include all hosts for ingress traffic..."

kubectl patch gateway platform-ui-gateway -n front-dev --type='json' -p='
[
  {"op": "replace", "path": "/spec/servers/0/hosts", "value": ["'${PLATFORM_UI_HOST}'", "'${ADMIN_DASHBOARD_HOST}'", "'${KEYCLOAK_HOST}'"]}
]
' || true # Use || true to prevent the script from stopping if the Gateway doesn't exist yet.

###########################################################
# 🚀 STEP 4 — Install/Upgrade Keycloak via Helm
###########################################################
echo "🛠️ Installing/Upgrading Keycloak in ${NAMESPACE} from ${CHART_PATH}..."
helm upgrade --install ${KEYCLOAK_RELEASE} ./${CHART_PATH} -n ${NAMESPACE} --wait

echo "⏳ Waiting for Keycloak pod to become ready..."
kubectl wait --for=condition=available deployment/${KEYCLOAK_RELEASE} -n ${NAMESPACE} --timeout=300s

###########################################################
# ✅ STEP 5 — Output Summary
###########################################################
echo ""
echo "✅ AUTH SYSTEM READY (Namespace: ${NAMESPACE})"
echo "---------------------------------------------"
echo "🌐 Keycloak URL:  https://${KEYCLOAK_HOST}"
echo "🧱 Realm: ${REALM}"
echo "👤 Admin: ${ADMIN_USER} / ${ADMIN_PASS}"
echo "---------------------------------------------"
echo "🔗 Platform Login:  https://${PLATFORM_UI_HOST}/login"
echo "🔗 Admin Dashboard: https://${ADMIN_DASHBOARD_HOST}"
echo ""
echo "📄 Helm Chart Location: ${CHART_PATH}"
echo "---------------------------------------------"
You can find an example of how to manage moving files in a shell script with [Bash Scripting Tutorial #11 Moving files into folders](https://www.youtube.com/watch?v=hPo8_cqxH5U).
http://googleusercontent.com/youtube_content/0