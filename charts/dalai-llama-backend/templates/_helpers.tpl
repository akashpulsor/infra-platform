{{/*
Common labels (matches istio-config pattern)
*/}}
{{- define "dalai-backend.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dalai-llama-backend
{{- end }}

{{/*
Gateway reference (matches istio-config)
*/}}
{{- define "dalai-backend.gatewayRef" -}}
{{ .Values.global.gateway.namespace }}/{{ .Values.global.gateway.name }}
{{- end }}

{{/*
JWKS URI (matches istio-config pattern)
*/}}
{{- define "dalai-backend.jwksUri" -}}
http://{{ .Values.keycloak.host }}/realms/{{ .Values.keycloak.realm }}/protocol/openid-connect/certs
{{- end }}

{{/*
Service labels
*/}}
{{- define "dalai-backend.serviceLabels" -}}
app: {{ .serviceName }}
app.kubernetes.io/name: {{ .serviceName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: dalai-llama-backend
{{- end }}