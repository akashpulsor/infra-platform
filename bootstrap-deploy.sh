#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_PATH="$SCRIPT_DIR"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/deploy/dalai-llama}"
INFRA_REPO_URL="${INFRA_REPO_URL:-https://github.com/your-org/infra-platform.git}"
INFRA_REPO_BRANCH="${INFRA_REPO_BRANCH:-main}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
ACME_EMAIL="${ACME_EMAIL:-admin@dalaillama.in}"
INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
SKIP_TOOL_INSTALL="${SKIP_TOOL_INSTALL:-false}"
SKIP_CLONE="${SKIP_CLONE:-true}"
SKIP_NAMESPACE_SETUP="${SKIP_NAMESPACE_SETUP:-false}"
SKIP_CERT_MANAGER="${SKIP_CERT_MANAGER:-false}"
SKIP_ISTIO="${SKIP_ISTIO:-false}"
SKIP_OBSERVABILITY="${SKIP_OBSERVABILITY:-false}"
SKIP_DEPLOY="${SKIP_DEPLOY:-false}"
ENABLE_PBX_CORE="${ENABLE_PBX_CORE:-false}"
ENABLE_AI_SERVICE="${ENABLE_AI_SERVICE:-false}"
INSTALL_KIND="${INSTALL_KIND:-false}"
CREATE_KIND_CLUSTER="${CREATE_KIND_CLUSTER:-false}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-dalai-llama}"

step() {
  echo
  echo "==> $1"
}

info() {
  echo "[INFO] $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command '$1' not found in PATH" >&2
    exit 1
  }
}

restart_workloads_in_namespace() {
  local namespace="$1"
  local resource="$2"
  local names

  names="$(kubectl get "$resource" -n "$namespace" -o name 2>/dev/null || true)"
  if [[ -z "$names" ]]; then
    info "No $resource found in namespace $namespace to restart"
    return
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    kubectl rollout restart -n "$namespace" "$name"
  done <<< "$names"
}

cleanup_keycloak_jobs() {
  info "Cleaning up stale Keycloak jobs"
  kubectl delete job -n apps keycloak-realm-import --ignore-not-found=true || true
  kubectl delete job -n apps keycloak-realm-import-managed --ignore-not-found=true || true
}

install_tools() {
  step "Installing required tools"
  sudo apt-get update
  sudo apt-get install -y git curl apt-transport-https ca-certificates gnupg lsb-release unzip jq

  if ! command -v kubectl >/dev/null 2>&1; then
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
      sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | \
      sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y kubectl
  fi

  if ! command -v helm >/dev/null 2>&1; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

  if [[ "$INSTALL_DOCKER" == "true" || "$INSTALL_KIND" == "true" || "$CREATE_KIND_CLUSTER" == "true" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
      step "Installing Docker"
      sudo apt-get update
      sudo apt-get install -y docker.io
      sudo systemctl enable docker
      sudo systemctl start docker
      if ! groups "$USER" | grep -q "\bdocker\b"; then
        sudo usermod -aG docker "$USER" || true
        info "Added $USER to docker group. Log out and back in if you want docker without sudo."
      fi
    fi
  fi

  if [[ "$INSTALL_KIND" == "true" || "$CREATE_KIND_CLUSTER" == "true" ]]; then
    if ! command -v kind >/dev/null 2>&1; then
      curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
      chmod +x ./kind
      sudo mv ./kind /usr/local/bin/kind
    fi
  fi

  if ! command -v istioctl >/dev/null 2>&1; then
    step "Installing istioctl"
    local istio_version="1.27.0"
    curl -L "https://github.com/istio/istio/releases/download/${istio_version}/istio-${istio_version}-linux-amd64.tar.gz" -o /tmp/istioctl.tar.gz
    tar -xzf /tmp/istioctl.tar.gz -C /tmp
    sudo mv "/tmp/istio-${istio_version}/bin/istioctl" /usr/local/bin/istioctl
    rm -rf /tmp/istio-"${istio_version}" /tmp/istioctl.tar.gz
  fi
}

clone_repo() {
  step "Cloning infrastructure repository"
  mkdir -p "$WORKSPACE_ROOT"
  local repo_name repo_path
  repo_name="$(basename "${INFRA_REPO_URL%.git}")"
  repo_path="$WORKSPACE_ROOT/$repo_name"

  if [[ -d "$repo_path" ]]; then
    echo "$repo_path"
    return
  fi

  require_cmd git
  git clone --branch "$INFRA_REPO_BRANCH" "$INFRA_REPO_URL" "$repo_path" >/dev/null
  echo "$repo_path"
}

ensure_kind_cluster() {
  if [[ "$CREATE_KIND_CLUSTER" != "true" ]]; then
    return
  fi

  step "Creating local kind cluster"
  require_cmd kind

  if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
    echo "kind cluster '$KIND_CLUSTER_NAME' already exists"
    return
  fi

  kind create cluster --name "$KIND_CLUSTER_NAME"
}

apply_cloudflare_issuer() {
  local repo_path="$1"

  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    echo "CLOUDFLARE_API_TOKEN is required to create the cert-manager secret and ClusterIssuer." >&2
    exit 1
  fi

  step "Configuring Cloudflare secret and ClusterIssuer"

  kubectl create secret generic cloudflare-api-token-secret \
    -n cert-manager \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  local template_path="$repo_path/cloudflare-clusterissuer.yaml"
  local generated_path="$repo_path/cloudflare-clusterissuer.generated.yaml"

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
            - "dalaillama.in"
        dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
EOF
  fi

  kubectl apply -f "$generated_path"
}

configure_optional_services() {
  local repo_path="$1"
  local values_path="$repo_path/charts/backend-service/values.yaml"

  if [[ "$ENABLE_PBX_CORE" == "true" ]]; then
    sed -i '/pbxCoreService:/,/^[^[:space:]]/ s/enabled: false/enabled: true/' "$values_path"
  fi

  if [[ "$ENABLE_AI_SERVICE" == "true" ]]; then
    sed -i '/aiService:/,/^[^[:space:]]/ s/enabled: false/enabled: true/' "$values_path"
  fi
}

run_deploy() {
  local repo_path="$1"
  cd "$repo_path"

  if [[ "$SKIP_NAMESPACE_SETUP" != "true" ]]; then
    step "Creating namespaces"
    kubectl apply -f istio-namespaces.yaml
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
  fi

  if [[ "$SKIP_CERT_MANAGER" != "true" ]]; then
    step "Installing cert-manager"
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --set installCRDs=true
    apply_cloudflare_issuer "$repo_path"
  fi

  if [[ "$SKIP_ISTIO" != "true" ]]; then
    step "Installing Istio"
    require_cmd istioctl
    istioctl install -y --set profile=default

    kubectl apply -f istio-namespaces.yaml
    kubectl label namespace infra istio-injection=disabled --overwrite
    kubectl label namespace apps istio-injection=enabled --overwrite
    restart_workloads_in_namespace apps deployment || true
    restart_workloads_in_namespace infra deployment || true
    restart_workloads_in_namespace infra statefulset || true
  fi

  if [[ "$SKIP_OBSERVABILITY" != "true" ]]; then
    step "Installing Istio observability addons"
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/prometheus.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/grafana.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/kiali.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/jaeger.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/extras/zipkin.yaml
  fi

  if [[ "$ENABLE_PBX_CORE" == "true" || "$ENABLE_AI_SERVICE" == "true" ]]; then
    step "Enabling optional backend services"
    configure_optional_services "$repo_path"
  fi

  if [[ "$SKIP_DEPLOY" != "true" ]]; then
    step "Building infra chart dependencies"
    helm dependency build charts/infra

    step "Deploying infra"
    helm upgrade --install infra charts/infra -n infra -f charts/infra/values.yaml -f charts/infra/values-secret.yaml

    step "Deploying Keycloak"
    cleanup_keycloak_jobs
    helm upgrade --install keycloak charts/keycloak -n apps -f charts/keycloak/values.yaml -f charts/keycloak/values-prod.yaml -f charts/keycloak/values-secret.yaml

    step "Deploying backend"
    helm upgrade --install backend charts/backend-service -n apps -f charts/backend-service/values.yaml -f charts/backend-service/values-secret.yaml

    step "Deploying platform UI"
    helm upgrade --install platform-ui charts/platform-ui -n apps -f charts/platform-ui/values.yaml

    step "Deploying dashboard UI"
    helm upgrade --install dashboard-ui charts/dashboard-ui -n apps -f charts/dashboard-ui/values.yaml

    step "Deploying creator UI"
    helm upgrade --install creator-ui charts/creator-ui -n apps -f charts/creator-ui/values.yaml

    step "Deploying gateway"
    helm upgrade --install gateway charts/gateway -n apps -f charts/gateway/values.yaml
  fi
}

echo "Dalai LLAMA Ubuntu bootstrap + deploy script"
echo "This assumes your values-secret.yaml files are already filled locally."
echo "It also assumes Cloudflare DNS is already set up for dalaillama.in."
echo "Default repo path: $DEFAULT_REPO_PATH"

if [[ "$SKIP_TOOL_INSTALL" != "true" ]]; then
  install_tools
fi

if [[ "$SKIP_CLONE" == "true" ]]; then
  REPO_PATH="$DEFAULT_REPO_PATH"
else
  REPO_PATH="$(clone_repo)"
fi

ensure_kind_cluster
run_deploy "$REPO_PATH"

step "Done"
echo "If you also need the telecom host stack, run ./tele_infra.sh separately on that host."
