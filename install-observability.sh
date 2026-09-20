#!/usr/bin/env bash
# Deploys the ops observability + auth stack on the same k3s cluster the app runs on.
#
# Three components, all off-the-shelf Helm charts, tuned for a single-node 16 GB Hetzner box:
#   * Loki (single-binary, filesystem storage) — pod-log aggregation
#   * Alloy (DaemonSet) — scrapes /var/log/pods into Loki
#   * oauth2-proxy — Keycloak-backed OIDC gate in front of Grafana/Kiali/Prom/Jaeger
#
# Idempotent: `helm upgrade --install` for each. Re-running upgrades in place. Skips components
# whose namespace/CRDs already exist and were installed by this script previously.
#
# What you need before running:
#   1. Keycloak realm `dalai-llama` has a client named `ops-dashboard` with:
#        - Client type: OpenID Connect
#        - Client authentication: ON
#        - Valid redirect URI: https://ops.dalaillama.in/oauth2/callback
#        - Web origins: https://ops.dalaillama.in
#      Copy the client secret; you will paste it in prompt below or export as
#      OAUTH2_PROXY_CLIENT_SECRET before running.
#   2. Realm role `dalai_admin` exists and is assigned to every operator account.
#   3. DNS: ops.dalaillama.in → the same LB IP as the rest of the platform.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISTIO_NS="istio-system"
APPS_NS="apps"
OPS_HOST="${OPS_HOST:-ops.dalaillama.in}"
KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-https://auth.dalaillama.in/realms/dalai-llama}"
OAUTH2_PROXY_CLIENT_ID="${OAUTH2_PROXY_CLIENT_ID:-ops-dashboard}"

# Keep the whole thing within roughly 400 MB extra RSS on the node -- see the resource blocks below.

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_env() {
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            die "$var is required. Export it before running (see comments at top of file)."
        fi
    done
}

install_loki() {
    log "Installing/upgrading Loki (single-binary, filesystem storage)"
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update grafana >/dev/null
    # Chart values chosen for a single-node cluster with limited RAM. Filesystem storage means
    # logs vanish if the loki pod moves nodes, which is fine here because there IS only one node.
    # 24 h retention keeps disk usage bounded without any cron; go higher only when there is a
    # separate volume mounted for /var/loki.
    # SingleBinary mode requires explicitly zeroing SimpleScalable's read/write/backend replicas
    # -- the chart's validate.yaml refuses to install if both modes have replicas set. Failing to
    # zero them out was the first attempt's install error.
    helm upgrade --install loki grafana/loki -n "$ISTIO_NS" \
        --set deploymentMode=SingleBinary \
        --set loki.commonConfig.replication_factor=1 \
        --set loki.storage.type=filesystem \
        --set loki.auth_enabled=false \
        --set 'loki.schemaConfig.configs[0].from=2024-04-01' \
        --set 'loki.schemaConfig.configs[0].store=tsdb' \
        --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
        --set 'loki.schemaConfig.configs[0].schema=v13' \
        --set 'loki.schemaConfig.configs[0].index.prefix=index_' \
        --set 'loki.schemaConfig.configs[0].index.period=24h' \
        --set 'loki.limits_config.retention_period=168h' \
        --set singleBinary.replicas=1 \
        --set read.replicas=0 \
        --set write.replicas=0 \
        --set backend.replicas=0 \
        --set singleBinary.persistence.enabled=true \
        --set singleBinary.persistence.size=10Gi \
        --set 'singleBinary.resources.requests.cpu=100m' \
        --set 'singleBinary.resources.requests.memory=256Mi' \
        --set 'singleBinary.resources.limits.memory=512Mi' \
        --set chunksCache.enabled=false \
        --set resultsCache.enabled=false \
        --set gateway.enabled=false \
        --set test.enabled=false \
        --set monitoring.selfMonitoring.enabled=false \
        --set monitoring.selfMonitoring.grafanaAgent.installOperator=false \
        --set monitoring.lokiCanary.enabled=false
}

install_alloy() {
    log "Installing/upgrading Alloy (DaemonSet, pod-log scrape → Loki)"
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update grafana >/dev/null

    # Alloy config: scrape every pod's stdout via Kubernetes discovery, forward to Loki. Adds
    # tenant/namespace/pod/container labels automatically; TenantMdcFilter's JSON MDC keys land
    # as top-level fields on each log line (Loki parses JSON via a stage).
    cat >/tmp/alloy-values.yaml <<'EOF'
controller:
  type: daemonset
alloy:
  configMap:
    create: true
    content: |
      logging {
        level  = "warn"
        format = "logfmt"
      }
      discovery.kubernetes "pods" {
        role = "pod"
      }
      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
      }
      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.process.parse_json.receiver]
      }
      loki.process "parse_json" {
        forward_to = [loki.write.default.receiver]
        stage.json {
          expressions = {
            level      = "level",
            tenant_id  = "tenant_id",
            project_id = "project_id",
            shot_id    = "shot_id",
            job_id     = "job_id",
            user_id    = "user_id",
            request_id = "request_id",
          }
        }
        stage.labels {
          values = {
            level      = "",
            tenant_id  = "",
            project_id = "",
            shot_id    = "",
            job_id     = "",
            user_id    = "",
            request_id = "",
          }
        }
      }
      loki.write "default" {
        endpoint {
          url = "http://loki.istio-system.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
  resources:
    requests:
      cpu: 50m
      memory: 96Mi
    limits:
      memory: 192Mi
serviceMonitor:
  enabled: false
EOF
    helm upgrade --install alloy grafana/alloy -n "$ISTIO_NS" -f /tmp/alloy-values.yaml
}

install_oauth2_proxy() {
    log "Installing/upgrading oauth2-proxy (Keycloak OIDC gate for ops.dalaillama.in)"
    helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests >/dev/null 2>&1 || true
    helm repo update oauth2-proxy >/dev/null

    # Client secret comes from the shared oauth2-proxy-secret that charts/backend-service pre-
    # creates (with a randAlphaNum default that Helm keeps stable across upgrades). Same secret
    # the keycloak-bootstrap Job reads via OPS_CLIENT_SECRET_DESIRED, so oauth2-proxy and
    # Keycloak's ops-dashboard client stay in lockstep by construction rather than by a manual
    # re-sync step. Requires charts/backend-service to have deployed at least once.
    if ! kubectl -n "$APPS_NS" get secret oauth2-proxy-secret >/dev/null 2>&1; then
        die "oauth2-proxy-secret missing in namespace ${APPS_NS}. Run \`helm upgrade backend ...\` first (its keycloak-bootstrap job creates the secret and syncs it into Keycloak)."
    fi
    local client_secret
    client_secret="$(kubectl -n "$APPS_NS" get secret oauth2-proxy-secret -o jsonpath='{.data.client-secret}' | base64 -d)"

    # Cookie secret must be exactly 16/24/32 raw bytes (base64 encoded is fine). Auto-generate
    # the first time and reuse across upgrades so browser sessions do not invalidate on every
    # deploy. Lives in the same namespace as oauth2-proxy for a straight secretKeyRef mount.
    local cookie_secret
    if kubectl -n "$APPS_NS" get secret oauth2-proxy-cookie >/dev/null 2>&1; then
        cookie_secret="$(kubectl -n "$APPS_NS" get secret oauth2-proxy-cookie -o jsonpath='{.data.value}' | base64 -d)"
    else
        cookie_secret="$(openssl rand -base64 32 | head -c 32)"
        kubectl -n "$APPS_NS" create secret generic oauth2-proxy-cookie \
            --from-literal=value="$cookie_secret"
    fi

    cat >/tmp/oauth2-proxy-values.yaml <<EOF
config:
  clientID: "${OAUTH2_PROXY_CLIENT_ID}"
  clientSecret: "${client_secret}"
  cookieSecret: "${cookie_secret}"
  configFile: |-
    provider = "keycloak-oidc"
    oidc_issuer_url = "${KEYCLOAK_ISSUER}"
    redirect_url = "https://${OPS_HOST}/oauth2/callback"
    email_domains = ["*"]
    # Only Keycloak users with the dalai_admin realm role pass. Everyone else sees a
    # forbidden page after login. This is the whole "admin only" enforcement -- do not
    # loosen without a second gate.
    allowed_roles = ["dalai_admin"]
    cookie_secure = true
    cookie_domains = [".dalaillama.in"]
    whitelist_domains = [".dalaillama.in"]
    upstreams = ["static://202"]
    reverse_proxy = true
    skip_provider_button = true
    scope = "openid profile email roles"
resources:
  requests:
    cpu: 20m
    memory: 32Mi
  limits:
    memory: 96Mi
service:
  portNumber: 4180
ingress:
  enabled: false
EOF
    helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy -n "$APPS_NS" -f /tmp/oauth2-proxy-values.yaml
}

patch_mesh_config_extension_provider() {
    log "Ensuring istio meshConfig has the oauth2-proxy extensionProvider (idempotent)"
    if kubectl -n "$ISTIO_NS" get configmap istio -o jsonpath='{.data.mesh}' | grep -q '^extensionProviders:'; then
        echo "  ✓ extensionProviders block already present"
        return 0
    fi
    # Append the extensionProviders block, restart istiod so it picks up the new config.
    local mesh_current
    mesh_current="$(kubectl -n "$ISTIO_NS" get configmap istio -o jsonpath='{.data.mesh}')"
    local mesh_updated
    mesh_updated="${mesh_current}
extensionProviders:
- name: oauth2-proxy
  envoyExtAuthzHttp:
    service: oauth2-proxy.apps.svc.cluster.local
    port: 4180
    pathPrefix: /oauth2/auth
    timeout: 5s
    includeRequestHeadersInCheck:
    - cookie
    - authorization
    - x-forwarded-for
    - x-forwarded-host
    - x-forwarded-proto
    - x-forwarded-uri
    headersToUpstreamOnAllow:
    - x-auth-request-user
    - x-auth-request-email
    - x-auth-request-access-token
    - authorization"
    kubectl -n "$ISTIO_NS" create configmap istio --from-literal=mesh="$mesh_updated" \
        --from-literal=meshNetworks='networks: {}' \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$ISTIO_NS" rollout restart deploy/istiod
    kubectl -n "$ISTIO_NS" rollout status deploy/istiod --timeout=120s
}

apply_ops_virtualservice() {
    log "Wiring VirtualService: ops.dalaillama.in → oauth2-proxy → Grafana/Kiali/Prometheus/Jaeger"
    kubectl apply -f "$SCRIPT_DIR/manifests/ops-virtualservice.yaml"
    kubectl apply -f "$SCRIPT_DIR/manifests/ops-oauth2-authz.yaml"
}

apply_grafana_loki_datasource() {
    log "Adding Loki as a Grafana datasource"
    kubectl apply -f "$SCRIPT_DIR/manifests/grafana-loki-datasource.yaml"
    # kubectl rollout restart picks up the new datasource ConfigMap on the next reconcile.
    kubectl -n "$ISTIO_NS" rollout restart deploy/grafana || true
}

main() {
    install_loki
    install_alloy
    install_oauth2_proxy
    patch_mesh_config_extension_provider
    apply_ops_virtualservice
    apply_grafana_loki_datasource
    log "Done. Visit https://${OPS_HOST}/grafana (or /kiali, /prom, /jaeger). Log in as a Keycloak user with the dalai_admin role."
}

main "$@"
