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
Traefik v3 routes nowhere.
invariant: a route behind private-access never matches a request that crossed Cloudflare.
The edge stamps `Cf-Ray` on everything it forwards and a client cannot strip it, while
the tunnel's traffic reaches Traefik from a pod address private-access admits; without
this, a private host was shielded from the internet only by the tunnel's hostname rules
in the Cloudflare dashboard (ADR-003). */}}
{{- define "common.ingressRoute" -}}
{{- $private := false -}}
{{- range .middlewares -}}{{- if eq .name "private-access" -}}{{- $private = true -}}{{- end -}}{{- end -}}
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
    - match: {{ if $private }}({{ .match }}) && !HeaderRegexp(`Cf-Ray`, `.+`){{ else }}{{ .match }}{{ end }}
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
