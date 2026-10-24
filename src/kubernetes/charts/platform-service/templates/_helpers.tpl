{{- define "platform-service.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "platform-service.host" -}}
{{- required "host is required" .Values.host -}}
{{- end -}}

{{- define "platform-service.labels" -}}
app.kubernetes.io/name: {{ include "platform-service.name" . }}
app.kubernetes.io/part-of: jterrazz-infrastructure
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
