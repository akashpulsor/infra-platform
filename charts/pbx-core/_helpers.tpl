{{- define "pbx-core.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}


{{- define "pbx-core.fullname" -}}
{{- printf "%s" (include "pbx-core.name" .) -}}
{{- end -}}


{{- define "pbx-core.labels" -}}
app.kubernetes.io/name: {{ include "pbx-core.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end -}}