{{/* Input dict: name, labels (rendered lines), secretName, dnsNames. */}}
{{- define "common.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  secretName: {{ .secretName }}
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    {{- range .dnsNames }}
    - {{ . }}
    {{- end }}
{{- end -}}
