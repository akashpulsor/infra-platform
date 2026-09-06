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
INSTALL_OBSERVABILITY="${INSTALL_OBSERVABILITY:-true}"
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
DNS_RECORDS="${DNS_RECORDS:-@ api auth creator media console monitor *}"
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
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "Full log of this run: $LOG_FILE" >&2
  fi
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

setup_logging() {
  # Every run's full output is captured to a timestamped file (in addition to
  # the terminal) so a failure -- including one caused by a dropped SSH
  # session, which loses terminal scrollback -- can still be diagnosed from
  # disk, and so the exact state of a run that self-healed a stuck Helm
  # release (see reconcile_stuck_helm_release) is on record. Kept as its own
  # top-level directory (not under .generated/) so it's easy to find.
  local log_dir="$REPO_PATH/deploymentlogs"
  mkdir -p "$log_dir"
  LOG_FILE="$log_dir/bootstrap-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  ln -sf "$LOG_FILE" "$log_dir/latest.log" 2>/dev/null || true
  echo "Logging this run to: $LOG_FILE"
}

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

  # The node object can take a moment to register after k3s starts; `kubectl wait --all`
  # errors immediately with "no matching resources found" if none exist yet instead of
  # waiting for one to appear, so poll for its existence first.
  for _ in $(seq 1 30); do
    [[ -n "$(kubectl get nodes --no-headers 2>/dev/null)" ]] && break
    sleep 2
  done

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

cloudflare_api_raw() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

cloudflare_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response
  response="$(cloudflare_api_raw "$method" "$path" "$body")" || fail "Cloudflare API request failed: $method $path"

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

upsert_cloudflare_dns_record() {
  # A hostname can be claimed by a Cloudflare Worker route/custom domain, which
  # owns DNS for that host and rejects normal record writes with error 81062
  # ("A DNS record managed by Workers already exists on that host"). That is not
  # a script bug or a duplicate-run issue -- it means the hostname already
  # resolves via the Worker, so treat it as a skip instead of a fatal error.
  local fqdn="$1"
  local body="$2"
  local id="$3"
  local method path response success error_code errors

  if [[ -n "$id" ]]; then
    method="PUT"
    path="/zones/$CLOUDFLARE_ZONE_ID/dns_records/$id"
  else
    method="POST"
    path="/zones/$CLOUDFLARE_ZONE_ID/dns_records"
  fi

  response="$(cloudflare_api_raw "$method" "$path" "$body")" || fail "Cloudflare API request failed: $method $path"
  success="$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || echo false)"
  if [[ "$success" == "true" ]]; then
    if [[ -n "$id" ]]; then
      info "Updated $fqdn"
    else
      info "Created $fqdn"
    fi
    return 0
  fi

  error_code="$(printf '%s' "$response" | jq -r '.errors[0].code // empty' 2>/dev/null || true)"
  if [[ "$error_code" == "81062" ]]; then
    warn "$fqdn is managed by a Cloudflare Worker route/custom domain; skipping (it already resolves via Workers)."
    return 0
  fi

  errors="$(printf '%s' "$response" | jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' 2>/dev/null || true)"
  fail "Cloudflare API error for $method $path: ${errors:-$response}"
}

upsert_cloudflare_dns_records() {
  [[ "$MANAGE_CLOUDFLARE_DNS" == "true" ]] || return 0

  need_cmd jq
  prompt_for_cloudflare_token
  detect_public_ip
  ensure_cloudflare_zone_id

  log "Upserting Cloudflare A records for $DOMAIN -> $PUBLIC_IP"
  local record fqdn fqdn_query id body

  # DNS_RECORDS is intentionally unquoted below to split on whitespace, but that
  # also means a literal "*" entry is a pathname-expansion glob: run from the
  # repo directory it silently expands to every file/dir there (this previously
  # created bogus A records named after files like bootstrap-cloud.sh). Disable
  # globbing for this loop so "*" stays a literal token.
  set -f
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

    upsert_cloudflare_dns_record "$fqdn" "$body" "$id"
  done
  set +f
}

install_cert_manager() {
  [[ "$INSTALL_CERT_MANAGER" == "true" ]] || return 0
  prompt_for_cloudflare_token
  validate_cloudflare_token
  ensure_cloudflare_zone_id

  log "Installing cert-manager"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack
  reconcile_stuck_helm_release cert-manager cert-manager
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

  apply_cloudflare_cluster_issuer
}

apply_cloudflare_cluster_issuer() {
  # charts/gateway's Certificate/Ingress resources reference this ClusterIssuer by name
  # (issuerRef / cert-manager.io/cluster-issuer: letsencrypt-prod) -- without it, deploy_gateway()
  # creates Certificate objects that can never be satisfied and wait_for_certificates() hangs for
  # the full HELM_TIMEOUT before failing.
  log "Applying Cloudflare ClusterIssuer"
  mkdir -p "$GENERATED_DIR"
  local template_path="$REPO_PATH/cloudflare-clusterissuer.yaml"
  local generated_path="$GENERATED_DIR/cloudflare-clusterissuer.generated.yaml"

  if [[ -f "$template_path" ]]; then
    sed "s/admin@dalaillama.in/${ACME_EMAIL}/g" "$template_path" > "$generated_path"
  else
    cat > "$generated_path" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: $ACME_EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - selector:
          dnsZones:
            - "$DOMAIN"
        dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
EOF
  fi

  kubectl apply -f "$generated_path"
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

helm_release_exists() {
  local release="$1"
  local namespace="$2"
  helm status "$release" -n "$namespace" >/dev/null 2>&1
}

reconcile_stuck_helm_release() {
  # If a previous run's SSH/network connection dropped mid `helm upgrade
  # --install`, Helm can be left believing that operation is still running:
  # the release sits in pending-install/pending-upgrade/pending-rollback and
  # every subsequent `helm upgrade --install` for it fails immediately with
  # "another operation (install/upgrade/rollback) is in progress", even
  # though nothing is actually running anymore. Detect and clear that before
  # attempting the real install/upgrade, so a rerun is self-healing instead
  # of requiring a manual `helm uninstall`/`helm rollback`.
  local release="$1"
  local namespace="$2"
  local status
  status="$(helm status "$release" -n "$namespace" -o json 2>/dev/null | jq -r '.info.status // empty' 2>/dev/null || true)"
  [[ -n "$status" ]] || return 0

  case "$status" in
    pending-install)
      warn "Helm release '$release' in namespace '$namespace' is stuck in status 'pending-install' (likely an interrupted first install, e.g. a dropped connection mid-run). It has no successful revision to fall back to, so removing it now to let this run install cleanly."
      helm uninstall "$release" -n "$namespace" >/dev/null 2>&1 || true
      ;;
    pending-upgrade|pending-rollback)
      local last_deployed
      last_deployed="$(helm history "$release" -n "$namespace" -o json 2>/dev/null | jq -r '[.[] | select(.status == "deployed")] | sort_by(.revision) | last | .revision // empty' 2>/dev/null || true)"
      if [[ -n "$last_deployed" ]]; then
        warn "Helm release '$release' in namespace '$namespace' is stuck in status '$status' (likely an interrupted upgrade); rolling back to its last successful revision ($last_deployed) so this run can upgrade it cleanly."
        helm rollback "$release" "$last_deployed" -n "$namespace" --wait --timeout "$HELM_TIMEOUT" >/dev/null 2>&1 || true
      else
        warn "Helm release '$release' in namespace '$namespace' is stuck in status '$status' with no successful revision on record; removing it now to let this run install cleanly."
        helm uninstall "$release" -n "$namespace" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

namespace_has_infra_data_volumes() {
  local namespace="$1"
  local count
  count="$(kubectl get pvc -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${count:-0}" -gt 0 ]]
}

reconcile_orphaned_infra_hook_secrets() {
  # charts/infra/templates/secrets.yaml creates postgres-secret/redis-secret/
  # minio-secret as pre-install,pre-upgrade hooks with
  # hook-delete-policy=before-hook-creation. That policy only deletes a hook
  # resource left over from a *tracked previous revision* of this same
  # release. If the "infra" release was ever uninstalled (Helm doesn't delete
  # hook resources on uninstall) or never finished installing, these Secrets
  # can be left behind with no owning release, so a fresh `helm install` hits
  # AlreadyExists trying to create them again.
  #
  # Distinguish fresh install from failover before touching anything:
  #   - live "infra" release present            -> normal upgrade, do nothing.
  #   - no release AND no infra PVCs             -> fresh install: nothing of
  #     value can be orphaned yet, safe to clear the stale secrets so the
  #     chart's hook can recreate them from values-secret.yaml.
  #   - no release BUT infra PVCs already exist  -> looks like a failover onto
  #     a cluster that already has postgres/redis/minio data; do NOT delete
  #     secrets automatically since a password mismatch with existing data
  #     needs a human to look at it. Fail with clear guidance instead.
  local namespace="infra"
  helm_release_exists infra "$namespace" && return 0

  local orphaned=()
  local secret
  for secret in postgres-secret redis-secret minio-secret; do
    kubectl get secret "$secret" -n "$namespace" >/dev/null 2>&1 && orphaned+=("$secret")
  done
  [[ "${#orphaned[@]}" -gt 0 ]] || return 0

  if namespace_has_infra_data_volumes "$namespace"; then
    fail "Secrets ${orphaned[*]} exist in namespace '$namespace' with no owning Helm release, and PVCs already exist there too (looks like a failover onto a cluster with existing data, not a fresh install). Refusing to auto-recreate these secrets since that could desync credentials from existing data. Inspect 'kubectl get pvc -n $namespace' and the secret contents, then resolve manually (e.g. restore the previous release's Secret values) before rerunning."
  fi

  warn "Fresh install detected: secrets ${orphaned[*]} exist in namespace '$namespace' with no owning Helm release and no data volumes (leftover from an earlier aborted/uninstalled run). Removing them so the infra chart's pre-install hook can recreate them from values-secret.yaml."
  for secret in "${orphaned[@]}"; do
    kubectl delete secret "$secret" -n "$namespace" >/dev/null
  done
}

deploy_infra() {
  log "Deploying infra"
  helm_dependency_build_if_needed "$REPO_PATH/charts/infra"
  reconcile_orphaned_infra_hook_secrets
  reconcile_stuck_helm_release infra infra
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
  reconcile_stuck_helm_release gateway istio-system
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
  reconcile_stuck_helm_release keycloak apps

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
  reconcile_stuck_helm_release backend apps

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
    for deployment in tenant-service billing-service product-service; do
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

  for deployment in tenant-service billing-service product-service; do
    kubectl rollout status "deployment/$deployment" -n apps --timeout="$ROLLOUT_TIMEOUT"
  done
}

deploy_ui() {
  [[ "$SKIP_UI" == "true" ]] && return 0

  # Only creator-ui is live for this client right now. platform-ui, dashboard-ui,
  # creative-worker-ui, and tenant-ui charts all still exist under charts/ and can be added here
  # the same way once they're actually needed.
  log "Deploying UIs"
  reconcile_stuck_helm_release creator-ui apps
  helm upgrade --install creator-ui "$REPO_PATH/charts/creator-ui" \
    -n apps -f "$REPO_PATH/charts/creator-ui/values.yaml" --wait --timeout "$HELM_TIMEOUT"

  kubectl rollout status deployment/creator-ui -n apps --timeout="$ROLLOUT_TIMEOUT"
}

install_observability() {
  [[ "$INSTALL_OBSERVABILITY" == "true" ]] || return 0
  log "Installing Istio observability addons"
  need_cmd awk
  need_cmd jq
  mkdir -p "$GENERATED_DIR"

  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/prometheus.yaml

  # Patch Grafana's addon manifest to add a real backend dashboard (JVM heap/
  # GC, HTTP request rate+latency, HikariCP pool) sourced from the
  # /actuator/prometheus metrics charts/backend-service's Deployments already
  # expose via prometheus.io/scrape annotations -- real data, not a blank
  # panel. Inserted as a new key into the existing
  # istio-services-grafana-dashboards ConfigMap (already mounted and
  # registered as a dashboard provider path by this same addon), so no
  # Deployment/volume changes are needed. The value is produced with jq
  # (already a dependency) rather than hand-escaped, and inserted via `sed r`
  # rather than `awk -v` -- awk's -v assignment interprets backslash escapes
  # in its argument, which corrupts a pre-escaped JSON string.
  local grafana_manifest="$GENERATED_DIR/grafana.generated.yaml"
  local dashboard_insert="$GENERATED_DIR/spring-boot-jvm-dashboard.insert.yaml"
  local dashboard_json="$REPO_PATH/charts/gateway/dashboards/spring-boot-jvm.json"
  if [[ -f "$dashboard_json" ]]; then
    printf '  spring-boot-jvm-dashboard.json: %s\n' \
      "$(jq -c . "$dashboard_json" | jq -Rs .)" > "$dashboard_insert"
    curl -fsSL https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/grafana.yaml \
      | awk '
          /istio-workload-dashboard\.json:/ { seen_workload=1 }
          seen_workload && /^kind: ConfigMap$/ && !inserted {
            print "__INSERT_SPRING_BOOT_DASHBOARD__"
            inserted=1
          }
          { print }
        ' \
      | sed -e "/__INSERT_SPRING_BOOT_DASHBOARD__/r $dashboard_insert" -e '/__INSERT_SPRING_BOOT_DASHBOARD__/d' \
      > "$grafana_manifest"
  else
    warn "charts/gateway/dashboards/spring-boot-jvm.json not found; deploying Grafana without the custom backend dashboard."
    curl -fsSL https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/grafana.yaml > "$grafana_manifest"
  fi
  kubectl apply -f "$grafana_manifest"

  # Jaeger instead of Zipkin: Kiali's tracing integration only supports
  # "jaeger" or "tempo" as a provider (verified against Kiali's config
  # source), so Zipkin traces could never surface inside Kiali's own
  # password-protected UI. Jaeger's addon also stands up a Service literally
  # named "zipkin" on :9411 that accepts Zipkin-format spans into the same
  # collector -- and the default IstioOperator profile (used by
  # install_istio() above) already points
  # meshConfig.defaultConfig.tracing.zipkin.address at that exact
  # "zipkin.istio-system:9411" address -- so sidecars keep sending spans with
  # zero mesh config changes, they just land in Jaeger's storage instead.
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/jaeger.yaml

  # Patch Kiali's addon manifest before applying it:
  #   - auth.strategy stays "anonymous" -- Kiali removed the built-in
  #     username/password "login" strategy (confirmed via pod logs: quay.io/
  #     kiali/kiali:v2.12 crash-loops with "FTL invalid authentication
  #     strategy [login]"). Kiali 2.x only accepts anonymous/openid/
  #     openshift/header, and openid would need a dedicated Keycloak client
  #     registration; anonymous is the option that actually starts without
  #     more infra, so this endpoint isn't password-gated by Kiali itself --
  #     rely on the generic hostname (below) for obscurity in the meantime.
  #   - server.web_root: /kiali -> / and add web_fqdn/web_schema/web_port,
  #     since it's served at its own dedicated host (monitor.$DOMAIN) rather
  #     than under a shared host's /kiali path -- without this Kiali
  #     generates broken links/redirects for its external URL.
  #   - liveness/readiness/startup probe paths: /kiali/healthz -> /healthz,
  #     to match the web_root change above. Without this the probes keep
  #     hitting the old /kiali/healthz path, get 404s against the app now
  #     serving at web_root "/", and kubelet kills+restarts the container
  #     forever even though Kiali itself started and is healthy.
  #   - external_services.tracing: enabled + provider: jaeger, pointed at the
  #     "tracing" Service (grpc-query :16685) Jaeger's addon creates, so
  #     traces show up inside Kiali's own UI instead of needing a separate
  #     tracing UI exposed on its own.
  local kiali_manifest="$GENERATED_DIR/kiali.generated.yaml"
  curl -fsSL https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/kiali.yaml \
    | awk -v host="monitor.$DOMAIN" '
        /^      web_root: \/kiali$/ { sub(/\/kiali$/, "/") }
        /path: \/kiali\/healthz$/ { sub(/\/kiali\/healthz$/, "/healthz") }
        /^      tracing:$/ { in_tracing=1 }
        in_tracing && /^        enabled: false$/ {
          sub(/enabled: false/, "enabled: true")
          print
          print "        provider: jaeger"
          print "        in_cluster_url: \"http://tracing.istio-system:16685/jaeger\""
          print "        use_grpc: true"
          in_tracing=0
          next
        }
        { print }
        /^      port: 20001$/ {
          print "      web_fqdn: " host
          print "      web_schema: https"
          print "      web_port: 443"
        }
      ' > "$kiali_manifest"
  kubectl apply -f "$kiali_manifest"

  # Grafana Faro (browser RUM) receiver for creator-ui, forwarding traces
  # into the Jaeger deployed above. See alloy-faro-receiver.yaml for why
  # (faro.receiver only supports logs/traces outputs, and there's no Loki
  # deployed yet, so Faro's own JS-error/console-log capture has nowhere to
  # go for now -- traces + web vitals correlate into Jaeger/Kiali).
  if [[ -f "$REPO_PATH/alloy-faro-receiver.yaml" ]]; then
    kubectl apply -f "$REPO_PATH/alloy-faro-receiver.yaml"
  fi

  kubectl rollout status deployment/prometheus -n istio-system --timeout="$ROLLOUT_TIMEOUT" || true
  kubectl rollout status deployment/grafana -n istio-system --timeout="$ROLLOUT_TIMEOUT" || true
  kubectl rollout status deployment/kiali -n istio-system --timeout="$ROLLOUT_TIMEOUT" || true
  kubectl rollout status deployment/jaeger -n istio-system --timeout="$ROLLOUT_TIMEOUT" || true
  kubectl rollout status deployment/alloy-faro -n istio-system --timeout="$ROLLOUT_TIMEOUT" || true

  info "Kiali (metrics + service graph + traces): https://monitor.$DOMAIN (once deploy_gateway/wait_for_certificates run) -- anonymous access, not password-gated (see install_observability comments)."
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
  local auth_code protected_code public_code
  auth_code="$(curl -fsS -o /dev/null -w '%{http_code}' "https://auth.$DOMAIN/realms/dalai-llama/.well-known/openid-configuration" || true)"
  # creator-service is decommissioned (see charts/backend-service/values.yaml,
  # not routed in charts/gateway/values.yaml) -- /api/v1/creator/* 404s at the
  # gateway with no matching route. tenant-service's /api/v1/tenants is the
  # live, JWT-protected route to probe instead.
  protected_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://api.$DOMAIN/api/v1/tenants" || true)"
  public_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://api.$DOMAIN/api/v1/public/tenant-config/bootstrap-check" || true)"

  [[ "$auth_code" == "200" ]] || fail "Keycloak public discovery check failed: HTTP $auth_code"
  [[ "$protected_code" == "401" || "$protected_code" == "403" ]] || fail "Tenant protected route expected 401/403, got HTTP $protected_code"
  [[ "$public_code" == "404" || "$public_code" == "200" ]] || fail "Tenant public route expected 404/200, got HTTP $public_code"

  info "auth.$DOMAIN discovery: HTTP $auth_code"
  info "api.$DOMAIN tenant protected route: HTTP $protected_code"
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
  echo
  echo "Full log of this run: $LOG_FILE"
}

main() {
  cd "$REPO_PATH"
  setup_logging
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
