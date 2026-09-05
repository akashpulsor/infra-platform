#!/usr/bin/env bash
set -Eeuo pipefail

# One-off cleanup for the bogus Cloudflare A records created by a bug in
# bootstrap-cloud.sh's DNS_RECORDS loop: the literal "*" entry underwent shell
# pathname expansion against the repo directory it ran from, creating an A
# record named after every file in that directory (e.g.
# bootstrap-cloud.sh.dalaillama.in, charts.dalaillama.in). That loop is fixed
# (wrapped in set -f) but the junk records it already created on the live
# zone are not cleaned up by that fix. Run this once to remove them.
#
# Usage:
#   ./cleanup-glob-dns-records.sh          # dry run: lists what would be deleted
#   ./cleanup-glob-dns-records.sh --apply  # actually deletes them
#
# Prompts for CLOUDFLARE_API_TOKEN (Zone:Read + DNS:Edit) if not exported.

DOMAIN="${DOMAIN:-dalaillama.in}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-$DOMAIN}"

APPLY="false"
[[ "${1:-}" == "--apply" ]] && APPLY="true"

# Exact junk hostnames observed in the bootstrap-cloud.sh run that hit the bug
# (repo file/dir names in ~/infra-platform, glob-expanded onto $DOMAIN).
JUNK_RECORDS=(
  "bootstrap-cloud.sh.$DOMAIN"
  "bootstrap-deploy.ps1.$DOMAIN"
  "bootstrap-deploy.sh.$DOMAIN"
  "build-and-push.sh.$DOMAIN"
  "charts.$DOMAIN"
  "cloudflare-clusterissuer.yaml.$DOMAIN"
  "deploy-keycloak-theme.sh.$DOMAIN"
  "install-istioctl.sh.$DOMAIN"
  "istio-namespaces.yaml.$DOMAIN"
  "kamailio.cfg.$DOMAIN"
  "tele_infra2.sh.$DOMAIN"
  "tele_infra.sh.$DOMAIN"
)

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found"
}
need_cmd curl
need_cmd jq

if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
    echo
  fi
  [[ -n "$CLOUDFLARE_API_TOKEN" ]] || fail "CLOUDFLARE_API_TOKEN is required."
fi

urlencode() { jq -nr --arg value "$1" '$value|@uri'; }

cloudflare_api() {
  local method="$1" path="$2" body="${3:-}" response
  if [[ -n "$body" ]]; then
    response="$(curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" --data "$body")"
  else
    response="$(curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json")"
  fi
  local success
  success="$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || echo false)"
  if [[ "$success" != "true" ]]; then
    local errors
    errors="$(printf '%s' "$response" | jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' 2>/dev/null || true)"
    fail "Cloudflare API error for $method $path: ${errors:-$response}"
  fi
  printf '%s\n' "$response"
}

if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
  info "Using CLOUDFLARE_ZONE_ID=$CLOUDFLARE_ZONE_ID"
else
  zone_query="$(urlencode "$CLOUDFLARE_ZONE_NAME")"
  CLOUDFLARE_ZONE_ID="$(cloudflare_api GET "/zones?name=$zone_query" | jq -r '.result[0].id // empty')"
  [[ -n "$CLOUDFLARE_ZONE_ID" ]] || fail "Could not resolve Cloudflare zone id for $CLOUDFLARE_ZONE_NAME"
  info "Resolved zone $CLOUDFLARE_ZONE_NAME -> $CLOUDFLARE_ZONE_ID"
fi

echo
if [[ "$APPLY" == "true" ]]; then
  info "Deleting junk A records:"
else
  info "Dry run (pass --apply to actually delete). Records that would be removed:"
fi

for fqdn in "${JUNK_RECORDS[@]}"; do
  fqdn_query="$(urlencode "$fqdn")"
  id="$(cloudflare_api GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$fqdn_query" | jq -r '.result[0].id // empty')"
  if [[ -z "$id" ]]; then
    info "  (not found, skipping) $fqdn"
    continue
  fi
  if [[ "$APPLY" == "true" ]]; then
    cloudflare_api DELETE "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$id" >/dev/null
    info "  deleted $fqdn"
  else
    info "  would delete $fqdn (id=$id)"
  fi
done

echo
if [[ "$APPLY" != "true" ]]; then
  info "Nothing was deleted. Re-run with --apply to actually remove these records."
fi
