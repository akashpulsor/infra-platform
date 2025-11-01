{{- define "admin.fullname" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "admin.labels" -}}
app.kubernetes.io/name: {{ include "admin.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/version: {{ .Chart.AppVersion }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
