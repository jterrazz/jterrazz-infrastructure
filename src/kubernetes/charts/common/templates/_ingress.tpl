{{/* Input dict: name, labels and annotations (rendered lines), match, public (bool),
middlewares ({ name, namespace? }, in order, after the access middleware), serviceName, servicePort.
invariant: one place decides what a private route is: private-access first, and a match that
never takes a request that crossed Cloudflare. The edge stamps `Cf-Ray` on everything it forwards,
and the tunnel reaches Traefik from a pod address private-access admits (ADR-003).
invariant: `tls: {}`: the default TLSStore serves the private zones' wildcards by SNI, and a
public route's TLS ends at the edge (ADR-001).
hazard: `match` is `Host(a) || Host(b)`, never v2's `Host(a, b)`, which the CRD accepts and
Traefik v3 routes nowhere. */}}
{{- define "common.ingressRoute" -}}
{{- $middlewares := .middlewares | default list -}}
{{- if not .public -}}
{{- $middlewares = prepend $middlewares (dict "name" "private-access" "namespace" "platform-networking") -}}
{{- end -}}
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
    - match: {{ if .public }}{{ .match }}{{ else }}({{ .match }}) && !HeaderRegexp(`Cf-Ray`, `.+`){{ end }}
      kind: Rule
      {{- if $middlewares }}
      middlewares:
        {{- range $middlewares }}
        - name: {{ .name }}
        {{- if .namespace }}
          namespace: {{ .namespace }}
        {{- end }}
        {{- end }}
      {{- end }}
      services:
        - name: {{ .serviceName }}
          port: {{ .servicePort }}
  tls: {}
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
