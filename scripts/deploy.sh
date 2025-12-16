#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# 🧩 CONFIGURATION (EDIT THESE VARIABLES)
# ==============================================

# Docker Registry
DOCKER_REGISTRY="docker.io/akashtripathi"   # 🔁 change this to your registry
DOCKER_USER="akashtripathi"                 # Jenkins will use this
DOCKER_PASSWORD="your-docker-password-or-token"    # or use Jenkins secret

# Image details
AUTH_API_IMAGE="${DOCKER_REGISTRY}/auth-api"
PLATFORM_API_IMAGE="${DOCKER_REGISTRY}/platform-api"
IMAGE_TAG="latest"

# Argo CD Git repository (infra repo)
ARGO_GIT_URL="https://github.com/your-org/infra-platform.git"
ARGO_GIT_REV="main"

# Namespace & host configs
AUTH_NS="auth-system"
PLATFORM_NS="platform-dev"
GATEWAY_NS="front-dev"
GATEWAY_NAME="platform-ui-gateway"

AUTH_RELEASE="auth-api"
PLATFORM_RELEASE="platform-api"

AUTH_HOST="auth-api.dev.localhost"
PLATFORM_HOST="api.dev.localhost"

CONTAINER_PORT=8080
SERVICE_PORT=8080

# ==============================================
echo ">>> Creating namespaces..."
for ns in "${AUTH_NS}" "${PLATFORM_NS}" "${GATEWAY_NS}" argocd; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
done

kubectl label ns "${AUTH_NS}" istio-injection=enabled --overwrite
kubectl label ns "${PLATFORM_NS}" istio-injection=enabled --overwrite

# ==============================================
echo ">>> Ensuring Istio Gateway exists..."
if ! kubectl get gateway "${GATEWAY_NAME}" -n "${GATEWAY_NS}" >/dev/null 2>&1; then
cat <<EOF | kubectl apply -n "${GATEWAY_NS}" -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
spec:
  selector:
    istio: ingress
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - ${AUTH_HOST}
    - ${PLATFORM_HOST}
    - platform-ui.dev.localhost
EOF
else
  echo "Gateway ${GATEWAY_NAME} already exists, skipping."
fi

# ==============================================
echo ">>> Creating reusable Helm chart (spring-boot)"
rm -rf helm/spring-boot
mkdir -p helm/spring-boot/templates

cat > helm/spring-boot/Chart.yaml <<'EOF'
apiVersion: v2
name: spring-boot
description: Generic Spring Boot service with Istio VirtualService
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

cat > helm/spring-boot/values.yaml <<EOF
image:
  repository: ${DOCKER_REGISTRY}/placeholder
  tag: ${IMAGE_TAG}
  pullPolicy: IfNotPresent

service:
  port: ${SERVICE_PORT}
  type: ClusterIP

containerPort: ${CONTAINER_PORT}

istio:
  enabled: true
  host: "dev.localhost"
  gatewayRef: "${GATEWAY_NS}/${GATEWAY_NAME}"
EOF

cat > helm/spring-boot/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "spring-boot.fullname" . }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ include "spring-boot.fullname" . }}
  template:
    metadata:
      labels:
        app: {{ include "spring-boot.fullname" . }}
    spec:
      containers:
      - name: app
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports:
        - containerPort: {{ .Values.containerPort }}
        readinessProbe:
          httpGet:
            path: /actuator/health/readiness
            port: {{ .Values.containerPort }}
          initialDelaySeconds: 10
        livenessProbe:
          httpGet:
            path: /actuator/health/liveness
            port: {{ .Values.containerPort }}
          initialDelaySeconds: 20
EOF

cat > helm/spring-boot/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "spring-boot.fullname" . }}
spec:
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.containerPort }}
  selector:
    app: {{ include "spring-boot.fullname" . }}
EOF

cat > helm/spring-boot/templates/virtualservice.yaml <<'EOF'
{{- if .Values.istio.enabled }}
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "spring-boot.fullname" . }}
spec:
  hosts:
  - {{ .Values.istio.host }}
  gateways:
  - {{ .Values.istio.gatewayRef }}
  http:
  - route:
    - destination:
        host: {{ include "spring-boot.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local
        port:
          number: {{ .Values.service.port }}
{{- end }}
EOF

cat > helm/spring-boot/templates/_helpers.tpl <<'EOF'
{{- define "spring-boot.fullname" -}}
{{ .Release.Name }}
{{- end }}
EOF

# ==============================================
echo ">>> Writing Helm values for auth and platform"
mkdir -p values

cat > values/auth-api.yaml <<EOF
image:
  repository: ${AUTH_API_IMAGE}
  tag: ${IMAGE_TAG}

istio:
  host: ${AUTH_HOST}
  gatewayRef: "${GATEWAY_NS}/${GATEWAY_NAME}"
EOF

cat > values/platform-api.yaml <<EOF
image:
  repository: ${PLATFORM_API_IMAGE}
  tag: ${IMAGE_TAG}

istio:
  host: ${PLATFORM_HOST}
  gatewayRef: "${GATEWAY_NS}/${GATEWAY_NAME}"
EOF

# ==============================================
echo ">>> Deploying auth-api..."
helm upgrade --install "${AUTH_RELEASE}" ./helm/spring-boot \
  -n "${AUTH_NS}" -f values/auth-api.yaml

echo ">>> Deploying platform-api..."
helm upgrade --install "${PLATFORM_RELEASE}" ./helm/spring-boot \
  -n "${PLATFORM_NS}" -f values/platform-api.yaml

# ==============================================
echo ">>> Creating Argo CD Applications..."
cat <<EOF | kubectl apply -n argocd -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${AUTH_RELEASE}
spec:
  project: default
  source:
    repoURL: ${ARGO_GIT_URL}
    targetRevision: ${ARGO_GIT_REV}
    path: apps/${AUTH_RELEASE}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${AUTH_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${PLATFORM_RELEASE}
spec:
  project: default
  source:
    repoURL: ${ARGO_GIT_URL}
    targetRevision: ${ARGO_GIT_REV}
    path: apps/${PLATFORM_RELEASE}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${PLATFORM_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ==============================================
echo "✅ Deployment complete!"
echo "🔹 Auth API → http://${AUTH_HOST}"
echo "🔹 Platform API → http://${PLATFORM_HOST}"
echo
echo "Test internal:"
echo "kubectl -n ${PLATFORM_NS} exec -it deploy/${PLATFORM_RELEASE} -- curl -s ${AUTH_RELEASE}.${AUTH_NS}.svc.cluster.local:${SERVICE_PORT}/actuator/health"
