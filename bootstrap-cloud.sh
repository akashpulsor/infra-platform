#!/usr/bin/env bash
set -Eeuo pipefail

# One-command cloud bootstrap for Dalai LLAMA.
#
# Intended use on a fresh Ubuntu cloud VM:
#   ./bootstrap-cloud.sh
#
# The script will securely prompt for CLOUDFLARE_API_TOKEN when it is not
# exported. The token needs Cloudflare Zone:Read and DNS:Edit permissions for
# the configured zone.
#
# Optional:
#   export CLOUDFLARE_ZONE_NAME=dalaillama.in
#   export PUBLIC_IP=1.2.3.4
#   export TENANT_CRED_ENCRYPTION_KEY="$(openssl rand -base64 32)"
#   export SKIP_UI=true
#   export ENABLE_PBX_CORE=true
#   export ENABLE_AI_SERVICE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="${REPO_PATH:-$SCRIPT_DIR}"

DOMAIN="${DOMAIN:-dalaillama.in}"
ACME_EMAIL="${ACME_EMAIL:-admin@dalaillama.in}"
K3S_INSTALL="${K3S_INSTALL:-auto}" # auto | true | false
INSTALL_TOOLS="${INSTALL_TOOLS:-true}"
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"
INSTALL_ISTIO="${INSTALL_ISTIO:-true}"
INSTALL_OBSERVABILITY="${INSTALL_OBSERVABILITY:-false}"
MANAGE_CLOUDFLARE_DNS="${MANAGE_CLOUDFLARE_DNS:-true}"
PROMPT_CLOUDFLARE_TOKEN="${PROMPT_CLOUDFLARE_TOKEN:-true}"
WAIT_FOR_CERTS="${WAIT_FOR_CERTS:-true}"
VERIFY_PUBLIC_ROUTES="${VERIFY_PUBLIC_ROUTES:-true}"
SKIP_UI="${SKIP_UI:-false}"
ENABLE_PBX_CORE="${ENABLE_PBX_CORE:-false}"
ENABLE_AI_SERVICE="${ENABLE_AI_SERVICE:-false}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-10m}"

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-$DOMAIN}"
CLOUDFLARE_PROXIED="${CLOUDFLARE_PROXIED:-false}"
CLOUDFLARE_TOKEN_VALIDATED="false"
PUBLIC_IP="${PUBLIC_IP:-}"
DNS_RECORDS="${DNS_RECORDS:-@ api auth platform dashboard creator media console *}"
TENANT_CRED_ENCRYPTION_KEY="${TENANT_CRED_ENCRYPTION_KEY:-}"

GENERATED_DIR="$REPO_PATH/.generated/cloud"
GENERATED_BACKEND_VALUES="$GENERATED_DIR/backend-secrets.generated.yaml"

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
fi

log() {
  echo
  echo "==> $*"
}

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  echo "[ERROR] bootstrap failed at line $1 (exit $exit_code)" >&2
  echo "Useful diagnostics:" >&2
  echo "  kubectl get pods -A" >&2
  echo "  helm list -A" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found"
}

apt_install() {
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y "$@"
  else
    warn "No apt-get/dnf/yum found; skipping package install for: $*"
  fi
}

install_tools() {
  [[ "$INSTALL_TOOLS" == "true" ]] || return 0

  log "Installing base tools"
  apt_install curl ca-certificates gnupg lsb-release jq git unzip openssl

  if ! command -v kubectl >/dev/null 2>&1; then
    log "Installing kubectl"
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
      $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
      $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    $SUDO apt-get update
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y kubectl
  fi

  if ! command -v helm >/dev/null 2>&1; then
    log "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

  if ! command -v istioctl >/dev/null 2>&1; then
    log "Installing istioctl"
    local istio_version="${ISTIO_VERSION:-1.27.2}"
    curl -fsSL "https://github.com/istio/istio/releases/download/${istio_version}/istio-${istio_version}-linux-amd64.tar.gz" \
      -o /tmp/istioctl.tar.gz
    tar -xzf /tmp/istioctl.tar.gz -C /tmp
    $SUDO mv "/tmp/istio-${istio_version}/bin/istioctl" /usr/local/bin/istioctl
    rm -rf "/tmp/istio-${istio_version}" /tmp/istioctl.tar.gz
  fi
}

cluster_is_available() {
  kubectl version --request-timeout=8s >/dev/null 2>&1
}

ensure_k3s_or_existing_cluster() {
  if cluster_is_available; then
    info "Using existing Kubernetes context: $(kubectl config current-context 2>/dev/null || echo default)"
    return 0
  fi

  if [[ "$K3S_INSTALL" == "false" ]]; then
    fail "No Kubernetes cluster is reachable and K3S_INSTALL=false"
  fi

  log "Installing single-node K3s without Traefik"
  if [[ -n "$SUDO" ]]; then
    curl -sfL https://get.k3s.io | \
      $SUDO INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644" sh -
  else
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644" sh -
  fi

  mkdir -p "$HOME/.kube"
  $SUDO cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  $SUDO chown "$(id -u):$(id -g)" "$HOME/.kube/config"
  export KUBECONFIG="$HOME/.kube/config"

  kubectl wait --for=condition=Ready nodes --all --timeout="$ROLLOUT_TIMEOUT"
}

ensure_repo_files() {
  [[ -d "$REPO_PATH/charts/infra" ]] || fail "charts/infra not found under $REPO_PATH"
  [[ -d "$REPO_PATH/charts/keycloak" ]] || fail "charts/keycloak not found under $REPO_PATH"
  [[ -d "$REPO_PATH/charts/backend-service" ]] || fail "charts/backend-service not found under $REPO_PATH"
  [[ -f "$REPO_PATH/charts/infra/values-secret.yaml" ]] || fail "charts/infra/values-secret.yaml is required"
  [[ -f "$REPO_PATH/charts/keycloak/values-secret.yaml" ]] || fail "charts/keycloak/values-secret.yaml is required"
  [[ -f "$REPO_PATH/charts/backend-service/values-secret.yaml" ]] || fail "charts/backend-service/values-secret.yaml is required"
}

ensure_namespaces() {
  log "Creating namespaces and labels"
  kubectl apply -f "$REPO_PATH/istio-namespaces.yaml"
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace infra istio-injection=disabled --overwrite
  kubectl label namespace apps istio-injection=enabled --overwrite
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP" ]]; then
    return 0
  fi
  PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -fsS --max-time 10 https://ifconfig.me || true)"
  fi
  [[ -n "$PUBLIC_IP" ]] || fail "Could not detect PUBLIC_IP. Set PUBLIC_IP explicitly."
}

cloudflare_is_required() {
  [[ "$MANAGE_CLOUDFLARE_DNS" == "true" || "$INSTALL_CERT_MANAGER" == "true" ]]
}

prompt_for_cloudflare_token() {
  cloudflare_is_required || return 0

  if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
    return 0
  fi

  if [[ "$PROMPT_CLOUDFLARE_TOKEN" == "true" && -t 0 ]]; then
    echo
    echo "Cloudflare token is required for DNS records and Let's Encrypt DNS-01 certificates."
    echo "Required permissions: Zone:Read and DNS:Edit for zone '$CLOUDFLARE_ZONE_NAME'."
    read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN || true
    echo
  fi

  [[ -n "$CLOUDFLARE_API_TOKEN" ]] || fail "CLOUDFLARE_API_TOKEN is required. Export it or run interactively so the script can prompt."
}

urlencode() {
  jq -nr --arg value "$1" '$value|@uri'
}

cloudflare_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response
  if [[ -n "$body" ]]; then
    response="$(curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body")" || fail "Cloudflare API request failed: $method $path"
  else
    response="$(curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json")" || fail "Cloudflare API request failed: $method $path"
  fi

  local success errors
  success="$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || echo false)"
  if [[ "$success" != "true" ]]; then
    errors="$(printf '%s' "$response" | jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' 2>/dev/null || true)"
    fail "Cloudflare API error for $method $path: ${errors:-$response}"
  fi

  printf '%s\n' "$response"
}

validate_cloudflare_token() {
  cloudflare_is_required || return 0
  [[ "$CLOUDFLARE_TOKEN_VALIDATED" == "true" ]] && return 0

  log "Validating Cloudflare token"
  local status
  status="$(cloudflare_api GET "/user/tokens/verify" | jq -r '.result.status // empty')"
  [[ "$status" == "active" ]] || fail "Cloudflare token is not active. Status: ${status:-unknown}"
  CLOUDFLARE_TOKEN_VALIDATED="true"
}

prepare_cloudflare() {
  cloudflare_is_required || return 0

  need_cmd jq
  prompt_for_cloudflare_token
  validate_cloudflare_token
  ensure_cloudflare_zone_id
}

ensure_cloudflare_zone_id() {
  prompt_for_cloudflare_token
  validate_cloudflare_token
  if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
    local configured_zone_name
    configured_zone_name="$(cloudflare_api GET "/zones/$CLOUDFLARE_ZONE_ID" | jq -r '.result.name // empty')"
    [[ -n "$configured_zone_name" ]] || fail "Could not read Cloudflare zone $CLOUDFLARE_ZONE_ID"
    info "Using Cloudflare zone id from CLOUDFLARE_ZONE_ID: $configured_zone_name ($CLOUDFLARE_ZONE_ID)"
    return 0
  fi
  local zone_query
  zone_query="$(urlencode "$CLOUDFLARE_ZONE_NAME")"
  CLOUDFLARE_ZONE_ID="$(cloudflare_api GET "/zones?name=$zone_query" | jq -r '.result[0].id // empty')"
  [[ -n "$CLOUDFLARE_ZONE_ID" ]] || fail "Could not resolve Cloudflare zone id for $CLOUDFLARE_ZONE_NAME"
  info "Resolved Cloudflare zone $CLOUDFLARE_ZONE_NAME -> $CLOUDFLARE_ZONE_ID"
}

upsert_cloudflare_dns_records() {
  [[ "$MANAGE_CLOUDFLARE_DNS" == "true" ]] || return 0

  need_cmd jq
  prompt_for_cloudflare_token
  detect_public_ip
  ensure_cloudflare_zone_id

  log "Upserting Cloudflare A records for $DOMAIN -> $PUBLIC_IP"
  local record fqdn fqdn_query id body
  for record in $DNS_RECORDS; do
    case "$record" in
      @) fqdn="$DOMAIN" ;;
      "*") fqdn="*.$DOMAIN" ;;
      *."$DOMAIN") fqdn="$record" ;;
      *) fqdn="$record.$DOMAIN" ;;
    esac

    fqdn_query="$(urlencode "$fqdn")"
    id="$(cloudflare_api GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$fqdn_query" | jq -r '.result[0].id // empty')"
    body="$(jq -n \
      --arg type "A" \
      --arg name "$fqdn" \
      --arg content "$PUBLIC_IP" \
      --argjson proxied "$CLOUDFLARE_PROXIED" \
      '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')"

    if [[ -n "$id" ]]; then
      cloudflare_api PUT "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$id" "$body" >/dev/null
      info "Updated $fqdn"
    else
      cloudflare_api POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$body" >/dev/null
      info "Created $fqdn"
    fi
  done
}

install_cert_manager() {
  [[ "$INSTALL_CERT_MANAGER" == "true" ]] || return 0
  prompt_for_cloudflare_token
  validate_cloudflare_token
  ensure_cloudflare_zone_id

  log "Installing cert-manager"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager \
    --set installCRDs=true \
    --wait \
    --timeout "$HELM_TIMEOUT"

  kubectl create secret generic cloudflare-api-token-secret \
    -n cert-manager \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  info "Cloudflare token secret is ready in namespace cert-manager"
}

install_istio() {
  [[ "$INSTALL_ISTIO" == "true" ]] || return 0

  log "Installing Istio"
  istioctl install -y \
    --set profile=default \
    --set meshConfig.defaultConfig.proxyMetadata.SECRET_TTL=720h \
    --set values.gateways.istio-ingressgateway.type=LoadBalancer

  kubectl rollout status deployment/istiod -n istio-system --timeout="$ROLLOUT_TIMEOUT"
  kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout="$ROLLOUT_TIMEOUT"
}

helm_dependency_build_if_needed() {
  local chart="$1"
  if [[ -d "$chart/charts" ]] && find "$chart/charts" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    info "Using vendored dependencies for $chart"
    return 0
  fi
  helm dependency build "$chart"
}

ensure_generated_backend_values() {
  mkdir -p "$GENERATED_DIR"

  if [[ -z "$TENANT_CRED_ENCRYPTION_KEY" && -f "$GENERATED_BACKEND_VALUES" ]]; then
    TENANT_CRED_ENCRYPTION_KEY="$(grep -E '^[[:space:]]+encryptionKey:' "$GENERATED_BACKEND_VALUES" | head -1 | sed -E 's/^[[:space:]]+encryptionKey:[[:space:]]*"?([^"]*)"?/\1/' || true)"
  fi

  if [[ -z "$TENANT_CRED_ENCRYPTION_KEY" ]]; then
    TENANT_CRED_ENCRYPTION_KEY="$(openssl rand -base64 32)"
  fi

  local decoded_len
  decoded_len="$(printf '%s' "$TENANT_CRED_ENCRYPTION_KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  [[ "$decoded_len" == "32" ]] || fail "TENANT_CRED_ENCRYPTION_KEY must be base64 for exactly 32 bytes. Got decoded length: $decoded_len"

  cat > "$GENERATED_BACKEND_VALUES" <<EOF
secrets:
  tenantServiceCredentials:
    values:
      encryptionKey: "$TENANT_CRED_ENCRYPTION_KEY"
EOF
  chmod 600 "$GENERATED_BACKEND_VALUES"
}

patch_optional_backend_services() {
  local args=()
  [[ "$ENABLE_PBX_CORE" == "true" ]] && args+=(--set services.pbxCoreService.enabled=true)
  [[ "$ENABLE_AI_SERVICE" == "true" ]] && args+=(--set services.aiService.enabled=true)
  if [[ "${#args[@]}" -gt 0 ]]; then
    printf '%s\n' "${args[@]}"
  fi
}

cleanup_jobs() {
  kubectl delete job -n apps keycloak-realm-import --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete job -n apps keycloak-realm-import-managed --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete job -n apps keycloak-realm-config --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete job -n apps keycloak-bootstrap --ignore-not-found=true >/dev/null 2>&1 || true
}

print_job_logs() {
  local namespace="$1"
  shift
  local job
  for job in "$@"; do
    if kubectl get job "$job" -n "$namespace" >/dev/null 2>&1; then
      warn "Logs for job/$job:"
      kubectl logs -n "$namespace" "job/$job" --tail=160 || true
    fi
  done
}

deploy_infra() {
  log "Deploying infra"
  helm_dependency_build_if_needed "$REPO_PATH/charts/infra"
  helm upgrade --install infra "$REPO_PATH/charts/infra" \
    -n infra \
    -f "$REPO_PATH/charts/infra/values.yaml" \
    -f "$REPO_PATH/charts/infra/values-secret.yaml" \
    --wait \
    --timeout "$HELM_TIMEOUT"

  for deployment in postgres redis kafka minio; do
    kubectl rollout status "deployment/$deployment" -n infra --timeout="$ROLLOUT_TIMEOUT"
  done
}

deploy_gateway() {
  log "Deploying public gateway"
  helm upgrade --install gateway "$REPO_PATH/charts/gateway" \
    -n istio-system \
    -f "$REPO_PATH/charts/gateway/values.yaml" \
    --set-string clusterIssuer.dns01.email="$ACME_EMAIL" \
    --wait \
    --timeout "$HELM_TIMEOUT"
}

deploy_keycloak() {
  log "Deploying Keycloak"
  cleanup_jobs

  if ! helm upgrade --install keycloak "$REPO_PATH/charts/keycloak" \
    -n apps \
    -f "$REPO_PATH/charts/keycloak/values.yaml" \
    -f "$REPO_PATH/charts/keycloak/values-prod.yaml" \
    -f "$REPO_PATH/charts/keycloak/values-secret.yaml" \
    --set jobs.realmImport.runOnUpgrade=true \
    --wait \
    --timeout "$HELM_TIMEOUT"; then
    warn "Keycloak Helm hooks failed. Printing logs and marking release deployed after rollout if core deployment is healthy."
    print_job_logs apps keycloak-realm-import keycloak-realm-config
    kubectl rollout status deployment/keycloak -n apps --timeout="$ROLLOUT_TIMEOUT"
    cleanup_jobs
    helm upgrade keycloak "$REPO_PATH/charts/keycloak" \
      -n apps \
      -f "$REPO_PATH/charts/keycloak/values.yaml" \
      -f "$REPO_PATH/charts/keycloak/values-prod.yaml" \
      -f "$REPO_PATH/charts/keycloak/values-secret.yaml" \
      --set jobs.realmImport.runOnUpgrade=true \
      --no-hooks \
      --wait \
      --timeout "$HELM_TIMEOUT"
  fi

  kubectl rollout status deployment/keycloak -n apps --timeout="$ROLLOUT_TIMEOUT"
}

deploy_backend() {
  log "Deploying backend services"
  ensure_generated_backend_values
  cleanup_jobs

  mapfile -t optional_args < <(patch_optional_backend_services)

  if ! helm upgrade --install backend "$REPO_PATH/charts/backend-service" \
    -n apps \
    -f "$REPO_PATH/charts/backend-service/values.yaml" \
    -f "$REPO_PATH/charts/backend-service/values-secret.yaml" \
    -f "$GENERATED_BACKEND_VALUES" \
    "${optional_args[@]}" \
    --wait \
    --timeout "$HELM_TIMEOUT"; then
    warn "Backend Helm hooks failed. Printing logs and marking release deployed after rollout if core deployments are healthy."
    print_job_logs apps keycloak-bootstrap
    for deployment in tenant-service billing-service creator-service; do
      kubectl rollout status "deployment/$deployment" -n apps --timeout="$ROLLOUT_TIMEOUT"
    done
    cleanup_jobs
    helm upgrade backend "$REPO_PATH/charts/backend-service" \
      -n apps \
      -f "$REPO_PATH/charts/backend-service/values.yaml" \
      -f "$REPO_PATH/charts/backend-service/values-secret.yaml" \
      -f "$GENERATED_BACKEND_VALUES" \
      "${optional_args[@]}" \
      --no-hooks \
      --wait \
      --timeout "$HELM_TIMEOUT"
  fi

  for deployment in tenant-service billing-service creator-service; do
    kubectl rollout status "deployment/$deployment" -n apps --timeout="$ROLLOUT_TIMEOUT"
  done
}

deploy_ui() {
  [[ "$SKIP_UI" == "true" ]] && return 0

  log "Deploying UIs"
  helm upgrade --install platform-ui "$REPO_PATH/charts/platform-ui" \
    -n apps -f "$REPO_PATH/charts/platform-ui/values.yaml" --wait --timeout "$HELM_TIMEOUT"
  helm upgrade --install dashboard-ui "$REPO_PATH/charts/dashboard-ui" \
    -n apps -f "$REPO_PATH/charts/dashboard-ui/values.yaml" --wait --timeout "$HELM_TIMEOUT"
  helm upgrade --install creator-ui "$REPO_PATH/charts/creator-ui" \
    -n apps -f "$REPO_PATH/charts/creator-ui/values.yaml" --wait --timeout "$HELM_TIMEOUT"
  helm upgrade --install creative-worker-ui "$REPO_PATH/charts/creative-worker-ui" \
    -n apps -f "$REPO_PATH/charts/creative-worker-ui/values.yaml" --wait --timeout "$HELM_TIMEOUT"

  for deployment in platform-ui dashboard-ui creator-ui creative-worker-ui; do
    kubectl rollout status "deployment/$deployment" -n apps --timeout="$ROLLOUT_TIMEOUT"
  done
}

install_observability() {
  [[ "$INSTALL_OBSERVABILITY" == "true" ]] || return 0
  log "Installing Istio observability addons"
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/prometheus.yaml
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/grafana.yaml
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/kiali.yaml
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/jaeger.yaml
}

wait_for_certificates() {
  [[ "$WAIT_FOR_CERTS" == "true" ]] || return 0

  log "Waiting for gateway TLS certificates"
  local certs
  certs="$(kubectl get certificate -n istio-system -o name 2>/dev/null || true)"
  if [[ -z "$certs" ]]; then
    warn "No cert-manager Certificate resources found yet"
    return 0
  fi
  while IFS= read -r cert; do
    [[ -z "$cert" ]] && continue
    kubectl wait --for=condition=Ready "$cert" -n istio-system --timeout="$HELM_TIMEOUT"
  done <<< "$certs"
}

verify_public_routes() {
  [[ "$VERIFY_PUBLIC_ROUTES" == "true" ]] || return 0

  log "Verifying public routes"
  local auth_code creator_code public_code
  auth_code="$(curl -fsS -o /dev/null -w '%{http_code}' "https://auth.$DOMAIN/realms/dalai-llama/.well-known/openid-configuration" || true)"
  creator_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://api.$DOMAIN/api/v1/creator/categories" || true)"
  public_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://api.$DOMAIN/api/v1/public/tenant-config/bootstrap-check" || true)"

  [[ "$auth_code" == "200" ]] || fail "Keycloak public discovery check failed: HTTP $auth_code"
  [[ "$creator_code" == "401" || "$creator_code" == "403" ]] || fail "Creator protected route expected 401/403, got HTTP $creator_code"
  [[ "$public_code" == "404" || "$public_code" == "200" ]] || fail "Tenant public route expected 404/200, got HTTP $public_code"

  info "auth.$DOMAIN discovery: HTTP $auth_code"
  info "api.$DOMAIN creator protected route: HTTP $creator_code"
  info "api.$DOMAIN tenant public route: HTTP $public_code"
}

summary() {
  log "Cluster summary"
  helm list -A
  kubectl get pods -n infra
  kubectl get pods -n apps
  echo
  echo "Ready URLs:"
  echo "  https://auth.$DOMAIN"
  echo "  https://auth.$DOMAIN/admin/"
  echo "  https://api.$DOMAIN/api/v1"
  echo "  https://creator.$DOMAIN"
  echo "  https://dashboard.$DOMAIN"
  echo "  https://platform.$DOMAIN"
}

main() {
  cd "$REPO_PATH"
  ensure_repo_files
  install_tools
  prepare_cloudflare
  ensure_k3s_or_existing_cluster
  ensure_namespaces
  upsert_cloudflare_dns_records
  install_cert_manager
  install_istio
  install_observability
  deploy_infra
  deploy_gateway
  deploy_keycloak
  deploy_backend
  deploy_ui
  wait_for_certificates
  verify_public_routes
  summary
}

main "$@"
