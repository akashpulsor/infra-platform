#!/bin/bash
# =============================================================
# Build & Push FreeSWITCH image with mod_audio_stream
# =============================================================
# Usage:
#   ./build.sh                    # build only
#   ./build.sh push               # build + push to Docker Hub
#   ./build.sh k3d                # build + import to k3d
#   ./build.sh push k3d           # build + push + import to k3d
# =============================================================

set -e

REPO="akashtripathi/dalaillama-freeswitch"
TAG="1.10-audiostream"
IMAGE="${REPO}:${TAG}"
K3D_CLUSTER="cc-local"

echo "══════════════════════════════════════════════════"
echo "Building: ${IMAGE}"
echo "══════════════════════════════════════════════════"

# Build (this will take 15-30 minutes first time due to FreeSWITCH compile)
docker build -t "${IMAGE}" -t "${REPO}:latest" .

echo "✅ Build complete: ${IMAGE}"

# Push to Docker Hub
if [[ "$*" == *"push"* ]]; then
    echo "Pushing to Docker Hub..."
    docker push "${IMAGE}"
    docker push "${REPO}:latest"
    echo "✅ Pushed: ${IMAGE}"
fi

# Import to k3d
if [[ "$*" == *"k3d"* ]]; then
    echo "Importing to k3d cluster: ${K3D_CLUSTER}..."
    k3d image import "${IMAGE}" -c "${K3D_CLUSTER}"
    k3d image import "${REPO}:latest" -c "${K3D_CLUSTER}"
    echo "✅ Imported to k3d"
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "Done! Update values.yaml:"
echo "  freeswitch:"
echo "    image:"
echo "      repository: ${REPO}"
echo "      tag: \"${TAG}\""
echo "══════════════════════════════════════════════════"
