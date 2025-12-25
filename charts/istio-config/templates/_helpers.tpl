{{/*
Common labels
*/}}
{{- define "istio-config.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Gateway full reference
*/}}
{{- define "istio-config.gatewayRef" -}}
{{ .Values.gateway.namespace }}/{{ .Values.gateway.name }}
{{- end }}

{{/*
Keycloak JWKS URI
*/}}
{{- define "istio-config.jwksUri" -}}
http://{{ .Values.keycloak.host }}{{ .Values.keycloak.jwksPath }}
{{- end }}