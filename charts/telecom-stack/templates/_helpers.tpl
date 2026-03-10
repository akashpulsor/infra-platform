{{/*
Namespace
*/}}
{{- define "telecom.namespace" -}}
{{- .Values.global.namespace | default "telecom" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "telecom.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dalai-llama
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- if .Values.global.tenantId }}
dalaillama.in/tenant-id: {{ .Values.global.tenantId }}
{{- end }}
dalaillama.in/deployment-model: {{ .Values.global.deploymentModel }}
{{- end }}

{{/*
Image pull secrets
*/}}
{{- define "telecom.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}