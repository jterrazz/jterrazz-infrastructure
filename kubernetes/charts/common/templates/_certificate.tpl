{{/*
One cert-manager Certificate, DNS-01 through the `letsencrypt-production`
ClusterIssuer — the only issuer either chart has ever used, so it is pinned
here rather than passed in.

Input dict: name, labels (rendered lines), secretName, dnsNames (list).
*/}}
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
