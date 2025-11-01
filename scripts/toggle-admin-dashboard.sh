#!/usr/bin/env bash
set -euo pipefail

# ==========================
# CONFIGURATION
# ==========================
export JENKINS_URL=http://localhost:8082
export JENKINS_USER=admin
export JENKINS_TOKEN=1182652d570c31169b8a9db5ff1f3c4b61

ACTION="${1:-deploy}"   # can be "deploy" or "destroy"
ENVIRONMENT="${2:-development}"

ARGOCD_SERVER="${ARGOCD_SERVER:-http://argocd-server.argocd.svc.cluster.local:80}"
ARGOCD_TOKEN="${ARGOCD_TOKEN:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJqZW5raW5zOmFwaUtleSIsIm5iZiI6MTc2MTgxNDM0MywiaWF0IjoxNzYxODE0MzQzLCJqdGkiOiI1MmNlOTQyNi0yMDdjLTRjZWMtODkzZS01ZTUyZGZiYTFkYTMifQ.0BaVEkJsk42G5A8IgVz8PIaNQ_PcAq7oEDOciNEsHac}"
APP_NAME="admin-dashboard-ui-${ENVIRONMENT}"
NAMESPACE="front-${ENVIRONMENT}"
REPO_URL="https://github.com/akashpulsor/infra-platform.git"
HELM_PATH="charts/admin-dashboard-ui"
DOCKER_USER="akashtripathi"
IMAGE_REPO="docker.io/${DOCKER_USER}/admin-dashboard-ui"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Helm environment values (you can customize per env)
if [[ "$ENVIRONMENT" == "development" ]]; then
  NODE_ENV="development"
  API_BASE_URL="https://api.dev.localhost"
  AUTH_ISSUER="https://auth.dev.localhost"
  ISTIO_HOST="admin.dashboard.dev.localhost"
elif [[ "$ENVIRONMENT" == "staging" ]]; then
  NODE_ENV="staging"
  API_BASE_URL="https://api.staging.localhost"
  AUTH_ISSUER="https://auth.staging.localhost"
  ISTIO_HOST="admin.dashboard.staging.localhost"
else
  NODE_ENV="production"
  API_BASE_URL="https://api.prod.localhost"
  AUTH_ISSUER="https://auth.prod.localhost"
  ISTIO_HOST="admin.dashboard.prod.localhost"
fi

# ==========================
# DEPLOY FUNCTION
# ==========================

deploy_app() {
  echo "🚀 Deploying ${APP_NAME} in namespace ${NAMESPACE}..."

  # Ensure namespace exists
  kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || {
    echo "🧱 Namespace ${NAMESPACE} not found. Creating..."
    kubectl create ns "${NAMESPACE}"
    kubectl label ns "${NAMESPACE}" istio-injection=enabled --overwrite
  }

  # Build ArgoCD Application JSON dynamically
  read -r -d '' APP_JSON <<EOF
{
  "metadata": {
    "name": "${APP_NAME}",
    "namespace": "argocd"
  },
  "spec": {
    "project": "default",
    "source": {
      "repoURL": "${REPO_URL}",
      "targetRevision": "main",
      "path": "${HELM_PATH}",
      "helm": {
        "parameters": [
          { "name": "image.repository", "value": "${IMAGE_REPO}" },
          { "name": "image.tag", "value": "${IMAGE_TAG}" },
          { "name": "env.NODE_ENV", "value": "${NODE_ENV}" },
          { "name": "env.API_BASE_URL", "value": "${API_BASE_URL}" },
          { "name": "env.AUTH_ISSUER", "value": "${AUTH_ISSUER}" },
          { "name": "env.CLIENT_ID", "value": "admin-dashboard-ui-${ENVIRONMENT}" },
          { "name": "istio.host", "value": "${ISTIO_HOST}" }
        ]
      }
    },
    "destination": {
      "server": "https://kubernetes.default.svc",
      "namespace": "${NAMESPACE}"
    },
    "syncPolicy": {
      "automated": { "prune": true, "selfHeal": true }
    }
  }
}
EOF

  # Create or update the application in ArgoCD
  echo "📡 Applying ArgoCD application..."
  curl -s -X POST \
    -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${APP_JSON}" \
    "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}" || true

  # Trigger a sync
  echo "🔁 Triggering ArgoCD sync..."
  curl -s -X POST \
    -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
    -H "Content-Type: application/json" \
    "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}/sync" >/dev/null

  echo "✅ ${APP_NAME} deployed and synced successfully."
}

# ==========================
# DESTROY FUNCTION
# ==========================

destroy_app() {
  echo "🔥 Destroying ${APP_NAME} deployment..."

  # Delete ArgoCD app
  curl -s -X DELETE \
    -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
    "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}" || true

  # Optionally clean namespace
  echo "🧹 Cleaning up Kubernetes resources..."
  kubectl delete ns "${NAMESPACE}" --ignore-not-found=true

  echo "✅ ${APP_NAME} destroyed successfully."
}

# ==========================
# MAIN SWITCH
# ==========================

case "${ACTION}" in
  deploy)
    deploy_app
    ;;
  destroy)
    destroy_app
    ;;
  *)
    echo "❌ Invalid action. Use 'deploy' or 'destroy'."
    exit 1
    ;;
esac
