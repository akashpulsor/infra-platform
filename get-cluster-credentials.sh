#!/usr/bin/env bash
set -Eeuo pipefail

# Dumps every credential this platform's kubectl context can see, decoded and
# labeled, so you don't have to re-run `kubectl get secret ... | base64 -d`
# by hand every time. Writes to .generated/cluster-credentials.txt (chmod 600,
# already gitignored) and prints to stdout.
#
# Usage: ./get-cluster-credentials.sh

REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$REPO_PATH/.generated/cluster-credentials.txt"
mkdir -p "$(dirname "$OUT")"

get_secret() {
  # get_secret <namespace> <secret-name> <key>
  kubectl get secret -n "$1" "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || echo "<not found>"
}

get_env() {
  # get_env <namespace> <deployment> <container-index> <env-var-name>
  kubectl get deployment -n "$1" "$2" -o jsonpath="{.spec.template.spec.containers[$3].env[?(@.name==\"$4\")].value}" 2>/dev/null || echo "<not found>"
}

{
  echo "==================================================================="
  echo " Cluster credentials -- generated $(date -u +%FT%TZ)"
  echo " Context: $(kubectl config current-context 2>/dev/null || echo unknown)"
  echo "==================================================================="

  echo
  echo "--- Postgres (superuser, infra namespace) ---"
  echo "host:     postgres.infra.svc.cluster.local:5432"
  echo "user:     postgres"
  echo "password: $(get_secret infra postgres-secret postgres-password)"

  echo
  echo "--- Redis (infra namespace) ---"
  echo "host:     redis.infra.svc.cluster.local:6379"
  echo "password: $(get_secret infra redis-secret redis-password)"

  echo
  echo "--- MinIO (infra namespace) ---"
  echo "console:  https://media.\$DOMAIN (or port-forward svc/minio)"
  echo "user:     $(get_secret infra minio-secret minio-root-user)"
  echo "password: $(get_secret infra minio-secret minio-root-password)"

  echo
  echo "--- Keycloak master admin (apps namespace) ---"
  echo "console:  https://auth.\$DOMAIN/admin"
  echo "user:     $(get_env apps keycloak 0 KC_BOOTSTRAP_ADMIN_USERNAME)"
  echo "password: $(get_secret apps keycloak-admin-secret password)"

  echo
  echo "--- Keycloak Postgres DB user (apps namespace) ---"
  echo "user:     $(get_secret apps keycloak-db-secret username)"
  echo "password: $(get_secret apps keycloak-db-secret password)"

  echo
  echo "--- Keycloak OIDC client secret (PLATFORM_API_SECRET, apps namespace) ---"
  echo "value:    $(get_secret apps keycloak-client-secret client-secret)"

  echo
  echo "--- Razorpay (apps namespace) ---"
  echo "key-id:         $(get_secret apps dalai-backend-razorpay key-id)"
  echo "key-secret:     $(get_secret apps dalai-backend-razorpay key-secret)"
  echo "webhook-secret: $(get_secret apps dalai-backend-razorpay webhook-secret)"

  echo
  echo "--- Cloudflare API token (cert-manager namespace) ---"
  echo "token:    $(get_secret cert-manager cloudflare-api-token-secret api-token)"

  echo
  echo "--- Kiali (istio-system namespace) ---"
  echo "console:  https://monitor.\$DOMAIN"
  echo "auth:     anonymous -- no credentials (see bootstrap-cloud.sh install_observability comments)"

  echo
  echo "==================================================================="
  echo " Add more services below as they're needed -- see get_secret()/get_env()"
  echo "==================================================================="
} | tee "$OUT"

chmod 600 "$OUT"
echo
echo "Saved to: $OUT (chmod 600, gitignored via .generated/)"
