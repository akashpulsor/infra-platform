#!/bin/bash
# setup-tls.sh - Setup TLS for local development

set -e

echo "=== DalaiLlama TLS Setup ==="

# Check cert-manager is installed
if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
  echo "❌ cert-manager not installed. Installing..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
  echo "⏳ Waiting for cert-manager to be ready..."
  kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s
  kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
  echo "✅ cert-manager installed"
else
  echo "✅ cert-manager already installed"
fi

# Deploy istio-config with TLS
echo ""
echo "📦 Deploying istio-config with TLS..."
helm upgrade --install istio-config ./istio-config \
  -n istio-system \
  -f ./istio-config/values.yaml

# Wait for certificate to be ready
echo ""
echo "⏳ Waiting for certificate to be issued..."
kubectl wait --for=condition=Ready certificate/dalaillama-dev-cert -n istio-system --timeout=120s
echo "✅ Certificate issued"

# Extract CA certificate for browser trust
echo ""
echo "📜 Extracting CA certificate..."
kubectl get secret dalaillama-root-ca-secret -n istio-system -o jsonpath='{.data.ca\.crt}' | base64 -d > dalaillama-ca.crt
kubectl get secret dalaillama-root-ca-secret -n istio-system -o jsonpath='{.data.tls\.crt}' | base64 -d >> dalaillama-ca.crt

echo ""
echo "=== ✅ TLS Setup Complete ==="
echo ""
echo "📋 Next Steps - Trust the CA in your browser/system:"
echo ""
echo "🪟 Windows:"
echo "   1. Double-click dalaillama-ca.crt"
echo "   2. Click 'Install Certificate'"
echo "   3. Select 'Local Machine' → Next"
echo "   4. Select 'Place all certificates in the following store'"
echo "   5. Browse → 'Trusted Root Certification Authorities' → OK → Next → Finish"
echo ""
echo "🍎 macOS:"
echo "   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain dalaillama-ca.crt"
echo ""
echo "🐧 Linux (Chrome/Chromium):"
echo "   certutil -d sql:\$HOME/.pki/nssdb -A -t 'C,,' -n 'DalaiLlama CA' -i dalaillama-ca.crt"
echo ""
echo "🦊 Firefox (all platforms):"
echo "   Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import"
echo ""
echo "🔗 Access your apps at:"
echo "   https://platform.dalaillama-dev.local"
echo "   https://auth.dalaillama-dev.local"
echo "   https://dashboard.dalaillama-dev.local"
echo ""
echo "⚠️  Don't forget to add entries to /etc/hosts (or C:\\Windows\\System32\\drivers\\etc\\hosts):"
echo "   127.0.0.1 dalaillama-dev.local platform.dalaillama-dev.local auth.localhost dashboard.dalaillama-dev.local"
