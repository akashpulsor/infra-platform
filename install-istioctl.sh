#!/usr/bin/env bash
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.27.0}"

echo "Installing istioctl ${ISTIO_VERSION}"
curl -L "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" -o /tmp/istioctl.tar.gz
tar -xzf /tmp/istioctl.tar.gz -C /tmp
sudo mv "/tmp/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
rm -rf /tmp/istio-"${ISTIO_VERSION}" /tmp/istioctl.tar.gz
istioctl version --remote=false
