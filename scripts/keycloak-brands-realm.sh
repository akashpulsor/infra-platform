#!/bin/bash
# Runs on the k3s box. Creates (or updates) the "brands" realm and its public PKCE client, separate
# from the creators' "dalai-llama" realm, so a brand and a creator can't collide on username.
set -euo pipefail
NS=apps
AP=$(kubectl get secret -n $NS keycloak-admin-secret -o jsonpath="{.data}" | python3 -c "import sys,json,base64;d=json.load(sys.stdin);print(base64.b64decode(list(d.values())[0]).decode())")
kc() { kubectl exec -i -n $NS deploy/keycloak -c keycloak -- /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master --user admin --password "$AP" >/dev/null

THEME=$(kc get realms/dalai-llama --fields loginTheme 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('loginTheme') or '')")
echo "creators' login theme: ${THEME:-default}"

if kc get realms/brands --fields realm >/dev/null 2>&1; then
  echo "realm brands exists"
else
  kc create realms -s realm=brands -s enabled=true -s displayName=Dalaillama >/dev/null
  echo "realm brands created"
fi
kc update realms/brands -s displayName="Dalaillama for brands" -s registrationAllowed=true -s registrationEmailAsUsername=true \
  -s loginWithEmailAllowed=true -s duplicateEmailsAllowed=false -s verifyEmail=false -s resetPasswordAllowed=true \
  -s rememberMe=true -s sslRequired=external ${THEME:+-s loginTheme=$THEME}

# Same mail server as the creators' realm (password reset and the like).
kc get realms/dalai-llama 2>/dev/null | python3 -c "import sys,json;print(json.dumps({'smtpServer':json.load(sys.stdin).get('smtpServer',{})}))" > /tmp/smtp.json
# The read masks the password; copy it from the backend's SMTP secret instead.
PW=$(kubectl get secret -n $NS dalai-backend-smtp -o jsonpath="{.data.smtp-password}" | base64 -d)
PW="$PW" python3 -c "import json,os;d=json.load(open('/tmp/smtp.json'));d['smtpServer']['password']=os.environ['PW'];json.dump(d,open('/tmp/smtp.json','w'))"
kc update realms/brands -f - < /tmp/smtp.json; rm -f /tmp/smtp.json
echo "brands realm mail server set"

CID=$(kc get clients -r brands -q clientId=brands-ui --fields id --format csv --noquotes 2>/dev/null | tail -1 | tr -d '\r')
ATTRS='{"pkce.code.challenge.method":"S256","post.logout.redirect.uris":"+"}'
REDIRECTS='["https://brands.dalaillama.in/*","https://platform.dalaillama.in/*","http://localhost:5173/*"]'
if [ -z "$CID" ]; then
  kc create clients -r brands -s clientId=brands-ui -s "name=Brands UI" -s enabled=true -s publicClient=true \
    -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s "redirectUris=$REDIRECTS" -s 'webOrigins=["+"]' \
    -s "attributes=$ATTRS" >/dev/null
  echo "client brands-ui created"
else
  kc update clients/$CID -r brands -s "redirectUris=$REDIRECTS" -s 'webOrigins=["+"]' -s "attributes=$ATTRS"
  echo "client brands-ui updated"
fi
kc get realms/brands --fields realm,registrationAllowed,registrationEmailAsUsername,verifyEmail,loginTheme
