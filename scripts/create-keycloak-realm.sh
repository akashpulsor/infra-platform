#!/bin/bash
set -e
export MSYS_NO_PATHCONV=1

# --- Configuration ---
REALM="dalai-llama"
ADMIN_USER="admin"
ADMIN_PASS="admin123"
KEYCLOAK_URL="http://127.0.0.1:8080"
FRONTEND_CLIENT_ID="platform-ui"
FRONTEND_REDIRECT_URI="https://platform-ui.dev.localhost/*"

# --- Check dependencies ---
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq not found. Please install it (e.g., sudo apt install jq -y)"
    exit 1
fi

# --- Helper: API call with response logging ---
api_call() {
    local method="$1"
    local url="$2"
    local data="$3"
    local token="$4"
    local expected_status="$5"
    local message="$6"

    echo ""
    echo "📡 API CALL → $method $url"
    echo "📦 Payload:"
    echo "$data" | jq . 2>/dev/null || echo "(no JSON body)"

    response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$data")

    # Separate body and HTTP status
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    echo "💬 Response HTTP $http_code:"
    echo "$response_body" | jq . 2>/dev/null || echo "$response_body"

    if [[ "$http_code" =~ ^($expected_status)$ ]]; then
        echo "✅ $message"
    elif [[ "$http_code" == "409" && "$message" == "Created realm ${REALM}" ]]; then
        echo "⚠️ Realm ${REALM} already exists. Skipping creation."
    elif [[ "$http_code" == "404" ]]; then
        echo "⚠️ Target not found. Skipping."
    else
        echo "❌ FAILED: $message"
        echo "   URL: $url"
        echo "   Response Body:"
        echo "$response_body"
        exit 1
    fi
}

# --- Step 0: Verify Keycloak Reachability ---
echo "🔍 Checking Keycloak at ${KEYCLOAK_URL} ..."
if ! curl -s "${KEYCLOAK_URL}/realms/master" | grep -q '"realm"'; then
    echo "❌ Keycloak is not reachable at ${KEYCLOAK_URL}/realms/master"
    echo "   Please ensure 'kubectl port-forward -n auth-system svc/keycloak 8080:8080' is active."
    exit 1
fi
echo "✅ Keycloak reachable."

# --- Step 1: Get Admin Token ---
echo ""
echo "🔐 Logging in as ${ADMIN_USER}..."
TOKEN_RESPONSE=$(curl -v -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" 2>&1)

echo ""
echo "💬 Token endpoint raw response:"
echo "$TOKEN_RESPONSE"

TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '"access_token":"[^"]+' | cut -d'"' -f4)
if [ -z "$TOKEN" ]; then
    echo "❌ Failed to retrieve admin token. Check credentials or Keycloak config."
    exit 1
fi
echo "✅ Logged in successfully."

# --- Step 2: Delete Realm if Exists ---
api_call "DELETE" "${KEYCLOAK_URL}/admin/realms/${REALM}" "" "$TOKEN" "204|404" "Deleted realm ${REALM} (if existed)"

# --- Step 3: Create Realm ---
REALM_DATA=$(cat <<EOF
{
  "realm": "${REALM}",
  "enabled": true,
  "registrationAllowed": true,
  "resetPasswordAllowed": true,
  "loginWithEmailAllowed": true,
  "sslRequired": "external"
}
EOF
)
api_call "POST" "${KEYCLOAK_URL}/admin/realms" "$REALM_DATA" "$TOKEN" "201" "Created realm ${REALM}"

# --- Step 4: Create Frontend Client ---
FRONTEND_CLIENT_DATA=$(cat <<EOF
{
  "clientId": "${FRONTEND_CLIENT_ID}",
  "publicClient": true,
  "redirectUris": ["${FRONTEND_REDIRECT_URI}","http://localhost:5173/*", "http://127.0.0.1:5173/*"],
  "webOrigins": ["*"],
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "attributes": {
    "pkce.code.challenge.method": "S256"
  }
}
EOF
)
api_call "POST" "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" "$FRONTEND_CLIENT_DATA" "$TOKEN" "201" "Created frontend PKCE client: ${FRONTEND_CLIENT_ID}"

# --- Step 5: Create Backend Client ---
BACKEND_CLIENT_DATA=$(cat <<EOF
{
  "clientId": "platform-dev-backend",
  "publicClient": false,
  "redirectUris": ["https://api.dev.localhost/*"],
  "webOrigins": ["+"],
  "standardFlowEnabled": true,
  "serviceAccountsEnabled": true,
  "authorizationServicesEnabled": true
}
EOF
)
api_call "POST" "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" "$BACKEND_CLIENT_DATA" "$TOKEN" "201" "Created backend client: dalai-backend"

echo ""
echo "✨ Script completed successfully!"
echo "   Realm: ${REALM}"
echo "   Frontend Client: ${FRONTEND_CLIENT_ID}"
echo "   Backend Client: platform-dev-backend"
