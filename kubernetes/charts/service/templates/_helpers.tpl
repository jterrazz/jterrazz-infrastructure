{{- define "service.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "service.host" -}}
{{- required "host is required" .Values.host -}}
{{- end -}}

{{/*
Stamped on every object this chart emits (IngressRoute, Certificate, PV, PVC).
`part-of: jterrazz-infrastructure` is a grouping label for `kubectl get -l`
spelunking only — nothing selects on it.
*/}}
{{- define "service.labels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/part-of: jterrazz-infrastructure
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
