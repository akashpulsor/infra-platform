#!/usr/bin/env bash
set -euo pipefail

# ================================
# CONFIG
# ================================
KC_URL="http://127.0.0.1:8080"
KC_ADMIN_USER="admin"
KC_ADMIN_PASS="admin123"
REALM="dalai-llama"

SPA_CLIENT_ID="platform-ui"
API_CLIENT_ID="platform-dev-backend"
BILLING_CLIENT_ID="billing-webhook"

SPA_REDIRECTS='["https://platform-ui.dev.localhost/*"]'
SPA_WEB_ORIGINS='["https://platform-ui.dev.localhost"]'
API_REDIRECTS='["https://api.dev.localhost/*"]'
API_WEB_ORIGINS='["https://api.dev.localhost"]'

REALM_ROLES=("super-admin" "platform-admin" "org-admin" "org-agent" "org-billing-manager")

# Global minimum balance policy (company-wide, in cents)
GLOBAL_MIN_BALANCE_CENTS=10000  # ₹100 default

# Tenants: name, subscription_tier, wallet, min_balance, status
TENANTS_JSON='[
  {"name":"acme","subscription_tier":"pro","plan":"monthly","status":"active","wallet_balance_cents":500000,"min_balance_cents":10000},
  {"name":"globex","subscription_tier":"free","plan":"free","status":"active","wallet_balance_cents":0,"min_balance_cents":0}
]'

SUPERADMIN_EMAIL="superadmin@example.com"
SUPERADMIN_PASS="admin123"
TENANT_ADMIN_PASS="admin123"

# ================================
# LOGIN
# ================================
echo "🔐 Logging into Keycloak..."
TOKEN=$(curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli" -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then echo "❌ Failed to get token"; exit 1; fi

kc_get() { curl -s -H "Authorization: Bearer $TOKEN" "$KC_URL$1"; }
kc_post() { curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST -d "$2" "$KC_URL$1"; }
kc_put() { curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X PUT -d "$2" "$KC_URL$1"; }

# ================================
# REALM & GLOBAL POLICY ATTRIBUTE
# ================================
REALM_EXISTS=$(kc_get "/admin/realms/$REALM" | jq -r '.realm' || true)
if [ "$REALM_EXISTS" != "$REALM" ]; then
  kc_post "/admin/realms" "{\"realm\":\"$REALM\",\"enabled\":true}" >/dev/null
fi

echo "🏢 Setting global minimum balance policy..."
curl -s -X PUT "$KC_URL/admin/realms/$REALM" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"attributes\":{\"global_min_balance_cents\":[\"$GLOBAL_MIN_BALANCE_CENTS\"]}}" >/dev/null

# ================================
# CLIENTS
# ================================
API_ID=$(kc_get "/admin/realms/$REALM/clients?clientId=$API_CLIENT_ID" | jq -r '.[0].id')
if [ -z "$API_ID" ]; then
  DATA=$(jq -n \
    --arg cid "$API_CLIENT_ID" \
    --argjson redirects "$API_REDIRECTS" \
    --argjson origins "$API_WEB_ORIGINS" \
    '{clientId:$cid, protocol:"openid-connect", publicClient:false, standardFlowEnabled:false,
      serviceAccountsEnabled:true, authorizationServicesEnabled:true, redirectUris:$redirects, webOrigins:$origins}')
  kc_post "/admin/realms/$REALM/clients" "$DATA" >/dev/null
  API_ID=$(kc_get "/admin/realms/$REALM/clients?clientId=$API_CLIENT_ID" | jq -r '.[0].id')
fi

# ================================
# ROLES
# ================================
for role in "${REALM_ROLES[@]}"; do
  R=$(kc_get "/admin/realms/$REALM/roles/$role" | jq -r '.name' || true)
  [ "$R" != "$role" ] && kc_post "/admin/realms/$REALM/roles" "{\"name\":\"$role\"}" >/dev/null
done

# ================================
# TENANT GROUP TREE
# ================================
ROOT_TENANTS_ID=$(kc_get "/admin/realms/$REALM/groups" | jq -r '.[] | select(.name=="tenants") | .id')
if [ -z "$ROOT_TENANTS_ID" ]; then
  ROOT_TENANTS_ID=$(curl -s -X POST "$KC_URL/admin/realms/$REALM/groups" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"tenants"}' -D - | grep Location | awk -F/ '{print $NF}' | tr -d '\r')
fi

create_subgroup() {
  local parent_id="$1"; local name="$2"
  local gid=$(kc_get "/admin/realms/$REALM/groups/$parent_id/children" | jq -r ".[] | select(.name==\"$name\") | .id")
  if [ -z "$gid" ]; then
    gid=$(curl -s -X POST "$KC_URL/admin/realms/$REALM/groups/$parent_id/children" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"name\":\"$name\"}" -D - | grep Location | awk -F/ '{print $NF}' | tr -d '\r')
  fi
  echo "$gid"
}

map_role_to_group() {
  local gid="$1"; local role="$2"
  local rid=$(kc_get "/admin/realms/$REALM/roles/$role" | jq -r '.id')
  kc_post "/admin/realms/$REALM/groups/$gid/role-mappings/realm" "[{\"id\":\"$rid\",\"name\":\"$role\"}]" >/dev/null
}

TENANTS_COUNT=$(echo "$TENANTS_JSON" | jq 'length')
for i in $(seq 0 $((TENANTS_COUNT-1))); do
  T=$(echo "$TENANTS_JSON" | jq ".[$i]")
  NAME=$(echo "$T" | jq -r '.name')
  PLAN=$(echo "$T" | jq -r '.plan')
  STATUS=$(echo "$T" | jq -r '.status')
  WALLET=$(echo "$T" | jq -r '.wallet_balance_cents')
  MINBAL=$(echo "$T" | jq -r '.min_balance_cents')
  TIER=$(echo "$T" | jq -r '.subscription_tier')

  TEN_ID=$(create_subgroup "$ROOT_TENANTS_ID" "$NAME")

  kc_put "/admin/realms/$REALM/groups/$TEN_ID" "$(jq -n \
    --arg n "$NAME" --arg p "$PLAN" --arg s "$STATUS" --arg w "$WALLET" --arg m "$MINBAL" --arg t "$TIER" \
    '{
      name:$n,
      attributes:{
        "tenant_id": [$n],
        "plan": [$p],
        "account_status": [$s],
        "wallet_balance_cents": [$w],
        "min_balance_cents": [$m],
        "subscription_tier": [$t]
      }
    }')" >/dev/null

  ADMIN_ID=$(create_subgroup "$TEN_ID" "Admins")
  AGENT_ID=$(create_subgroup "$TEN_ID" "Agents")
  map_role_to_group "$ADMIN_ID" "org-admin"
  map_role_to_group "$AGENT_ID" "org-agent"

  if [ "$i" -eq 0 ]; then
    USER_EMAIL="admin+$NAME@example.com"
    USER_ID=$(kc_get "/admin/realms/$REALM/users?username=$USER_EMAIL" | jq -r '.[0].id // empty')
    if [ -z "$USER_ID" ]; then
      USER_ID=$(curl -s -X POST "$KC_URL/admin/realms/$REALM/users" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "{\"username\":\"$USER_EMAIL\",\"email\":\"$USER_EMAIL\",\"enabled\":true}" \
        -D - | grep Location | awk -F/ '{print $NF}' | tr -d '\r')
    fi
    curl -s -X PUT "$KC_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"type\":\"password\",\"value\":\"$TENANT_ADMIN_PASS\",\"temporary\":false}" >/dev/null
    kc_put "/admin/realms/$REALM/users/$USER_ID/groups/$ADMIN_ID" "{}" >/dev/null || true
  fi
done

# ================================
# SUPERADMIN
# ================================
SUPERADMIN_ID=$(kc_get "/admin/realms/$REALM/users?username=$SUPERADMIN_EMAIL" | jq -r '.[0].id // empty')
if [ -z "$SUPERADMIN_ID" ]; then
  SUPERADMIN_ID=$(curl -s -X POST "$KC_URL/admin/realms/$REALM/users" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"username\":\"$SUPERADMIN_EMAIL\",\"email\":\"$SUPERADMIN_EMAIL\",\"enabled\":true}" \
    -D - | grep Location | awk -F/ '{print $NF}' | tr -d '\r')
fi
curl -s -X PUT "$KC_URL/admin/realms/$REALM/users/$SUPERADMIN_ID/reset-password" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"type\":\"password\",\"value\":\"$SUPERADMIN_PASS\",\"temporary\":false}" >/dev/null
RID=$(kc_get "/admin/realms/$REALM/roles/super-admin" | jq -r '.id')
kc_post "/admin/realms/$REALM/users/$SUPERADMIN_ID/role-mappings/realm" "[{\"id\":\"$RID\",\"name\":\"super-admin\"}]" >/dev/null

# ================================
# AUTHORIZATION POLICY UPDATE (is-tenant-active extended)
# ================================
AUTHZ_BASE="/admin/realms/$REALM/clients/$API_ID/authz/resource-server"
JS_CODE=$'var t = context.getIdentity().getToken().getOtherClaims().get("tenant");\nif (t == null) { $evaluation.deny(); quit(); }\nvar realmAttr = $evaluation.getRealm().getAttribute("global_min_balance_cents");\nvar globalMin = realmAttr == null ? 0 : Number(realmAttr.iterator().next());\nvar status = String(t.get("status"));\nvar tier = String(t.get("subscription_tier"));\nvar bal = Number(t.get("wallet_balance_cents"));\nvar min = Number(t.get("min_balance_cents"));\nvar effectiveMin = Math.max(globalMin, isNaN(min) ? 0 : min);\nif (status !== "active") { $evaluation.deny(); }\nelse if (!isNaN(bal) && bal < effectiveMin) { $evaluation.deny(); }\nelse if (tier === "free" && context.getAttributes().containsKey("premiumFeature")) { $evaluation.deny(); }\nelse { $evaluation.grant(); }'
curl -s -X POST "$KC_URL$AUTHZ_BASE/policy/js" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -n --arg code "$JS_CODE" '{name:"is-tenant-active", type:"js", logic:"POSITIVE", decisionStrategy:"UNANIMOUS", code:$code}')" >/dev/null || true

echo ""
echo "✅ Multi-tenant SaaS bootstrap complete!"
echo "🌐 Realm: $REALM"
echo "🏢 Global Min Balance: $GLOBAL_MIN_BALANCE_CENTS cents"
echo "👑 Superadmin: $SUPERADMIN_EMAIL / $SUPERADMIN_PASS"
echo "👥 Tenants:"
echo "$TENANTS_JSON" | jq -r '.[] | "- " + .name + " (" + .subscription_tier + ")"'
