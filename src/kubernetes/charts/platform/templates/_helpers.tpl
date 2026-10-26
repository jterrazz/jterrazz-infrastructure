{{- define "platform.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "platform.host" -}}
{{- required "host is required" .Values.host -}}
{{- end -}}

{{- define "platform.labels" -}}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/part-of: studio-infrastructure
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
