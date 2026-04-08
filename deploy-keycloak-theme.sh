#!/bin/bash
# deploy-keycloak-theme.sh
# Creates ConfigMap from theme files and patches Keycloak deployment to mount them

set -e

NAMESPACE="apps"
THEME_DIR="keycloak-theme"

echo "═══════════════════════════════════════════"
echo "  Deploying Dalai LLAMA Keycloak Theme"
echo "═══════════════════════════════════════════"

# ── 1. Create ConfigMap from theme files ──
echo "▶ Creating ConfigMap..."
kubectl create configmap keycloak-theme -n $NAMESPACE \
  --from-file=theme.properties=$THEME_DIR/dalaillama/login/theme.properties \
  --from-file=login.css=$THEME_DIR/dalaillama/login/resources/css/login.css \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ ConfigMap created"

# ── 2. Patch Keycloak deployment to mount theme ──
echo "▶ Patching Keycloak deployment..."
kubectl patch deployment keycloak -n $NAMESPACE --type strategic -p '
{
  "spec": {
    "template": {
      "spec": {
        "volumes": [
          {
            "name": "dalaillama-theme",
            "configMap": {
              "name": "keycloak-theme",
              "items": [
                {"key": "theme.properties", "path": "dalaillama/login/theme.properties"},
                {"key": "login.css", "path": "dalaillama/login/resources/css/login.css"}
              ]
            }
          }
        ],
        "containers": [
          {
            "name": "keycloak",
            "volumeMounts": [
              {
                "name": "dalaillama-theme",
                "mountPath": "/opt/keycloak/themes/dalaillama",
                "subPath": "dalaillama"
              }
            ]
          }
        ]
      }
    }
  }
}'

echo "  ✓ Deployment patched — Keycloak will restart"

# ── 3. Wait for rollout ──
echo "▶ Waiting for Keycloak to restart..."
kubectl rollout status deployment/keycloak -n $NAMESPACE --timeout=120s
echo "  ✓ Keycloak is running"

# ── 4. Set theme on realm ──
echo "▶ Setting theme on dalai-llama realm..."
KEYCLOAK_POD=$(kubectl get pods -n $NAMESPACE -l app=keycloak -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it $KEYCLOAK_POD -n $NAMESPACE -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user A --password P

kubectl exec -it $KEYCLOAK_POD -n $NAMESPACE -- /opt/keycloak/bin/kcadm.sh update realms/dalai-llama \
  -s loginTheme=dalaillama

echo "  ✓ Theme set on dalai-llama realm"

echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ Theme deployed!"
echo "  Test: https://auth.dalaillama.in/realms/dalai-llama/account"
echo "═══════════════════════════════════════════"