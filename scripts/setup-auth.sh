#!/bin/bash
set -e

###########################################################
# 🔧 CONFIGURATION
###########################################################
# This script automates a full Keycloak OIDC setup in Kubernetes.
# It:
#  - Creates a dedicated namespace (`auth-system`)
#  - Installs Keycloak (via Helm chart)
#  - Configures realm, clients, roles, and test user
#  - Exposes Keycloak through Istio Gateway
#  - Adds local /etc/hosts entries for browser resolution
#  - Outputs URLs, credentials, and next steps

# 👉 Adjust as per your environment:
NAMESPACE="auth-system"                       # 🧩 Dedicated namespace for Keycloak
REALM="dalai-llama"                           # Realm name (multi-tenant or environment scope)
KEYCLOAK_RELEASE="keycloak"                   # Helm release name
KEYCLOAK_HOST="auth.dev.localhost"            # Public host for Keycloak
ADMIN_USER="admin"                            # Default admin user
ADMIN_PASS="admin123"                         # Default admin password
USER_NAME="akash"                             # Default test user
USER_PASS="password123"                       # Default test password

# Related app hosts (so browser resolves everything locally)
PLATFORM_UI_HOST="platform-ui.dev.localhost"
ADMIN_DASHBOARD_HOST="admin-dashboard.dev.localhost"

###########################################################
# 🧱 STEP 1 — Namespace & Host Entries
###########################################################
echo "🚀 Creating namespace ${NAMESPACE} (if missing)..."
kubectl get ns ${NAMESPACE} >/dev/null 2>&1 || kubectl create ns ${NAMESPACE}


###########################################################
# ⚙️ STEP 2 — Create Helm Chart for Keycloak
###########################################################
# Official Keycloak container: https://hub.docker.com/r/quay.io/keycloak/keycloak
# Admin CLI reference:        https://www.keycloak.org/docs/latest/server_admin/#the-admin-cli

echo "📦 Generating Keycloak Helm chart (charts/keycloak)..."
mkdir -p charts/keycloak/templates

cat <<EOF > charts/keycloak/Chart.yaml
apiVersion: v2
name: keycloak
description: Self-hosted Keycloak for development & testing
version: 0.2.0
appVersion: "26.0"
EOF

cat <<EOF > charts/keycloak/values.yaml
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
cat <<EOF > charts/keycloak/templates/deployment.yaml
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
cat <<EOF > charts/keycloak/templates/service.yaml
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

# --- Istio Virtual Service
cat <<EOF > charts/keycloak/templates/virtualservice.yaml
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
    - route:
        - destination:
            host: keycloak.${NAMESPACE}.svc.cluster.local
            port:
              number: 8080
EOF

###########################################################
# 🚀 STEP 3 — Install Keycloak via Helm
###########################################################
echo "🛠️ Installing Keycloak in ${NAMESPACE}..."
helm upgrade --install ${KEYCLOAK_RELEASE} ./charts/keycloak -n ${NAMESPACE} --wait

echo "⏳ Waiting for Keycloak pod to become ready..."
kubectl wait --for=condition=available deployment/${KEYCLOAK_RELEASE} -n ${NAMESPACE} --timeout=300s

###########################################################
# 🔐 STEP 4 — Configure Realm, Clients, Roles, Users
###########################################################
# CLI ref: https://www.keycloak.org/docs/latest/server_admin/#the-admin-cli

KEYCLOAK_POD=$(kubectl get pods -n ${NAMESPACE} -l app=keycloak -o jsonpath='{.items[0].metadata.name}')

echo "🔑 Logging into Keycloak admin CLI..."
MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user ${ADMIN_USER} \
  --password ${ADMIN_PASS}

# --- Create realm
MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
  /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=${REALM} -s enabled=true || true

# --- Create OIDC clients for Platform UI and Admin Dashboard
echo "⚙️ Creating OIDC clients..."
declare -A CLIENTS
CLIENTS["platform-ui-development"]="https://${PLATFORM_UI_HOST}/*"
CLIENTS["admin-dashboard-ui-development"]="https://${ADMIN_DASHBOARD_HOST}/*"

for client in "${!CLIENTS[@]}"; do
  MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
    /opt/keycloak/bin/kcadm.sh create clients -r ${REALM} \
    -s clientId=${client} \
    -s enabled=true \
    -s 'redirectUris=["'${CLIENTS[$client]}'"]' \
    -s 'webOrigins=["*"]' \
    -s publicClient=true -s directAccessGrantsEnabled=true || true
done

# --- Create roles
echo "🧩 Creating user roles..."
for role in super-admin platform-admin org-admin; do
  MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
    /opt/keycloak/bin/kcadm.sh create roles -r ${REALM} -s name=${role} || true
done

# --- Create a test user
echo "👤 Creating default user ${USER_NAME}..."
MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
  /opt/keycloak/bin/kcadm.sh create users -r ${REALM} \
  -s username=${USER_NAME} -s enabled=true -s email="${USER_NAME}@dev.localhost" || true

USER_ID=$(MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
  /opt/keycloak/bin/kcadm.sh get users -r ${REALM} -q username=${USER_NAME} --fields id --format csv --noquotes | tail -1)

MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
  /opt/keycloak/bin/kcadm.sh set-password -r ${REALM} --userid ${USER_ID} --new-password ${USER_PASS}

for role in super-admin platform-admin; do
  MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
    /opt/keycloak/bin/kcadm.sh add-roles -r ${REALM} --uusername ${USER_NAME} --rolename ${role}
done

# --- Enable registration & password reset
echo "🧭 Enabling user self-registration & reset password..."
MSYS_NO_PATHCONV=1 kubectl exec -n ${NAMESPACE} ${KEYCLOAK_POD} -- \
  /opt/keycloak/bin/kcadm.sh update realms/${REALM} \
  -s "registrationAllowed=true" \
  -s "loginWithEmailAllowed=true" \
  -s "resetPasswordAllowed=true"

###########################################################
# ✅ STEP 5 — Output Summary
###########################################################
echo ""
echo "✅ AUTH SYSTEM READY (Namespace: ${NAMESPACE})"
echo "---------------------------------------------"
echo "🌐 Keycloak URL:     https://${KEYCLOAK_HOST}"
echo "🧱 Realm:            ${REALM}"
echo "👤 Admin:            ${ADMIN_USER} / ${ADMIN_PASS}"
echo "👤 Test User:        ${USER_NAME} / ${USER_PASS}"
echo "🧩 Roles:            super-admin, platform-admin, org-admin"
echo "---------------------------------------------"
echo "🔗 Platform Login:   https://${PLATFORM_UI_HOST}/login"
echo "🔗 Register:         https://${PLATFORM_UI_HOST}/register"
echo "🔗 Admin Dashboard:  https://${ADMIN_DASHBOARD_HOST}"
echo ""
echo "📄 Add to .env:"
echo "REACT_APP_AUTH_ISSUER=https://${KEYCLOAK_HOST}/realms/${REALM}"
echo "REACT_APP_CLIENT_ID=platform-ui-development"
echo ""
echo "📘 Learn more:"
echo "  - https://www.keycloak.org/docs/latest/server_admin/#the-admin-cli"
echo "  - https://www.keycloak.org/getting-started/getting-started-kube"
echo "  - https://www.keycloak.org/docs/latest/server_admin/#_clients"
echo "---------------------------------------------"