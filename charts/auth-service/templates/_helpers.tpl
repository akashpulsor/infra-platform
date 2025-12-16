{{/*
Generate a full name for resources
*/}}
{{- define "auth-service.fullname" -}}
{{- printf "%s-%s" .Release.Name "auth-service" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
