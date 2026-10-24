{{/* hazard: one access middleware per route, never chained; `private` is the default. */}}
{{- define "common.accessMiddleware" -}}
{{- $access := . | default "private" -}}
{{- if eq $access "private" -}}
private-access
{{- else if ne $access "public" -}}
{{- fail (printf "access must be one of private|public, got %q" $access) -}}
{{- end -}}
{{- end -}}

{{/* Input dict: name, labels and annotations (rendered lines), match, middlewares
({ name, namespace? }, in order), serviceName, servicePort, tlsSecret.
hazard: `match` is `Host(a) || Host(b)`, never v2's `Host(a, b)`, which the CRD accepts and
Traefik v3 routes nowhere. */}}
{{- define "common.ingressRoute" -}}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .name }}
  {{- if .annotations }}
  annotations:
    {{- .annotations | nindent 4 }}
  {{- end }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: {{ .match }}
      kind: Rule
      {{- if .middlewares }}
      middlewares:
        {{- range .middlewares }}
        - name: {{ .name }}
        {{- if .namespace }}
          namespace: {{ .namespace }}
        {{- end }}
        {{- end }}
      {{- end }}
      services:
        - name: {{ .serviceName }}
          port: {{ .servicePort }}
  tls:
    secretName: {{ .tlsSecret }}
{{- end -}}

{{/* Input dict: name, labels, prefix. */}}
{{- define "common.middleware.stripPrefix" -}}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  stripPrefix:
    prefixes:
      - {{ .prefix }}
{{- end -}}

{{/* Input dict: name, labels, host, replacement. The regex anchors the scheme, so a path that
contains the host is never rewritten. */}}
{{- define "common.middleware.redirect" -}}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  redirectRegex:
    regex: ^https?://{{ .host | replace "." "\\." }}/(.*)
    replacement: {{ .replacement }}
    permanent: true
{{- end -}}
