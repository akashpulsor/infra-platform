#!/bin/bash

# Define the root directory for the Helm chart
CHART_DIR="pbx-core-chart"
TEMPLATES_DIR="$CHART_DIR/templates"

echo "Creating Helm chart directory structure: $CHART_DIR/"
mkdir -p $TEMPLATES_DIR
mkdir -p $CHART_DIR/tests

# --- 1. Chart.yaml ---
echo "Generating $CHART_DIR/Chart.yaml"
cat << EOF > $CHART_DIR/Chart.yaml
apiVersion: v2
name: pbx-core-chart
description: A Helm chart for the pbx-core backend service, dependencies, and Istio configuration.
type: application
version: 0.1.0
appVersion: "1.0.0"

dependencies:
- name: mysql
  version: "9.6.x"  # Use a stable version
  repository: "https://charts.bitnami.com/bitnami"
  condition: dependencies.mysql.enabled
- name: redis
  version: "18.3.x" # Use a stable version
  repository: "https://charts.bitnami.com/bitnami"
  condition: dependencies.redis.enabled
- name: kafka
  version: "25.3.x" # Use a stable version
  repository: "https://charts.bitnami.com/bitnami"
  condition: dependencies.kafka.enabled
EOF

# --- 2. values.yaml ---
echo "Generating $CHART_DIR/values.yaml"
cat << EOF > $CHART_DIR/values.yaml
replicaCount: 1

image:
  repository: myrepo/pbx-core # Update this to your actual image
  pullPolicy: IfNotPresent
  tag: "latest" # Update this to your desired tag

service:
  type: ClusterIP
  port: 8080 # Internal cluster port

# --- Istio Configuration (CRITICAL) ---
istio:
  enabled: true
  # Based on discovery: <namespace>/<gateway-name>
  gateway: "front-dev/platform-ui-gateway" 
  # The public host used for accessing this service
  host: "api.platform-dev.mydomain.com" 

# --- Horizontal Pod Autoscaler Configuration ---
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

# --- Dependency Configuration (Subchart Settings) ---
dependencies:
  mysql:
    enabled: true
    serviceName: pbx-core-mysql # Service name used by pbx-core
    auth:
      rootPassword: "my-secure-root-password" 
      database: pbx_core_db
      username: pbx_user
      password: "pbx-user-password"
    primary:
      service:
        name: pbx-core-mysql # Ensure this matches serviceName above
  
  redis:
    enabled: true
    serviceName: pbx-core-redis # Service name used by pbx-core
    master:
      service:
        name: pbx-core-redis # Ensure this matches serviceName above

  kafka:
    enabled: true
    serviceName: pbx-core-kafka # Service name used by pbx-core
    kraft:
      enabled: true
    replicaCount: 1 
    service:
      name: pbx-core-kafka # Ensure this matches serviceName above

# Resource requests/limits for the pbx-core application
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi
EOF

# --- 3. _helpers.tpl (MANDATORY for functions) ---
echo "Generating $TEMPLATES_DIR/_helpers.tpl"
cat << EOF > $TEMPLATES_DIR/_helpers.tpl
{{/*
Expand the name of the chart.
*/}}
{{- define "pbx-core-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because of K8s name restrictions.
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pbx-core-chart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- \$name := default .Chart.Name .Values.nameOverride }}
{{- if contains \$name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name \$name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pbx-core-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pbx-core-chart.labels" -}}
helm.sh/chart: {{ include "pbx-core-chart.chart" . }}
{{ include "pbx-core-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pbx-core-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pbx-core-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{/*
Create the name of the service account to use
*/}}
{{- define "pbx-core-chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pbx-core-chart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
EOF

# --- 4. serviceaccount.yaml (Required by Deployment) ---
echo "Generating $TEMPLATES_DIR/serviceaccount.yaml"
cat << EOF > $TEMPLATES_DIR/serviceaccount.yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "pbx-core-chart.serviceAccountName" . }}
  labels:
    {{- include "pbx-core-chart.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount | default true }}
{{- end }}
EOF


# --- 5. deployment.yaml ---
echo "Generating $TEMPLATES_DIR/deployment.yaml"
cat << EOF > $TEMPLATES_DIR/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "pbx-core-chart.fullname" . }}
  labels:
    {{- include "pbx-core-chart.labels" . | nindent 4 }}
    app: pbx-core 
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "pbx-core-chart.selectorLabels" . | nindent 6 }}
      app: pbx-core
  template:
    metadata:
      labels:
        {{- include "pbx-core-chart.selectorLabels" . | nindent 8 }}
        app: pbx-core # Istio Policy Target
    spec:
      serviceAccountName: {{ include "pbx-core-chart.serviceAccountName" . }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8080 
              protocol: TCP
          env:
            # Dependency Service References
            - name: DB_HOST
              value: {{ .Values.dependencies.mysql.serviceName }}
            - name: DB_NAME
              value: {{ .Values.dependencies.mysql.auth.database }}
            - name: DB_USER
              value: {{ .Values.dependencies.mysql.auth.username }}
            - name: DB_PASSWORD
              valueFrom: 
                secretKeyRef:
                  name: {{ printf "%s-%s" .Release.Name "mysql" }} # Assumes the default secret naming from Bitnami
                  key: mysql-root-password # Use the root password key for demo
            - name: REDIS_HOST
              value: {{ .Values.dependencies.redis.serviceName }}
            - name: KAFKA_BROKERS
              value: {{ .Values.dependencies.kafka.serviceName }}:9092
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF

# --- 6. service.yaml ---
echo "Generating $TEMPLATES_DIR/service.yaml"
cat << EOF > $TEMPLATES_DIR/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "pbx-core-chart.fullname" . }}
  labels:
    {{- include "pbx-core-chart.labels" . | nindent 4 }}
    app: pbx-core
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    {{- include "pbx-core-chart.selectorLabels" . | nindent 4 }}
    app: pbx-core
EOF

# --- 7. hpa.yaml ---
echo "Generating $TEMPLATES_DIR/hpa.yaml"
cat << EOF > $TEMPLATES_DIR/hpa.yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "pbx-core-chart.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "pbx-core-chart.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "pbx-core-chart.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    {{- if .Values.autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
    {{- end }}
{{- end }}
EOF

# --- 8. istio-virtualservice.yaml ---
echo "Generating $TEMPLATES_DIR/istio-virtualservice.yaml"
cat << EOF > $TEMPLATES_DIR/istio-virtualservice.yaml
{{- if .Values.istio.enabled }}
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: {{ include "pbx-core-chart.fullname" . }}-vs
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "pbx-core-chart.labels" . | nindent 4 }}
spec:
  hosts:
    - "{{ .Values.istio.host }}" 
  gateways:
    - {{ .Values.istio.gateway }} # e.g., front-dev/platform-ui-gateway
  http:
    - name: pbx-core-route
      route:
      - destination:
          host: {{ include "pbx-core-chart.fullname" . }} 
          port:
            number: 8080
{{- end }}
EOF

# --- 9. istio-authorizationpolicy.yaml ---
echo "Generating $TEMPLATES_DIR/istio-authorizationpolicy.yaml"
cat << EOF > $TEMPLATES_DIR/istio-authorizationpolicy.yaml
{{- if .Values.istio.enabled }}
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: {{ include "pbx-core-chart.fullname" . }}-min-freemium-policy
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "pbx-core-chart.labels" . | nindent 4 }}
spec:
  # Targets the pbx-core Deployment
  selector:
    matchLabels:
      app: pbx-core
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["*"] 
    when:
    # Allows access if the user has the 'freemium', 'premium', OR 'enterprise' role
    - key: request.auth.claims[groups] 
      values: 
        - "freemium"
        - "premium"
        - "enterprise"
{{- end }}
EOF

echo ""
echo "✅ Success! The Helm chart structure has been generated in the '$CHART_DIR' directory."
echo "Next steps:"
echo "1. Run 'helm dependency update $CHART_DIR' to download the MySQL, Redis, and Kafka subcharts."
echo "2. Review and update the 'myrepo/pbx-core' image and passwords in '$CHART_DIR/values.yaml'."
