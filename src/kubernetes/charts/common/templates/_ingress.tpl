{{/* Input dict: name, labels and annotations (rendered lines), match, public (bool),
middlewares ({ name, namespace? }, in order), serviceName, servicePort.
invariant: one place decides what a public route is. A public route lives on the `tunnel`
entrypoint alone, the only one cloudflared reaches, with no TLS of ours (the edge terminates it,
ADR-001); a private route on `websecure` alone, which only the tailnet reaches, served the
private zones' wildcards by the default TLSStore. A request that crossed Cloudflare therefore has
no private route to match, by construction (ADR-002).
invariant: the target annotation is what external-dns publishes: a proxied CNAME from each public
host to `tunnel.jterrazz.com`, the tunnel's one alias (dns.yml; hand-synced-pairs.md).
hazard: `match` is `Host(a) || Host(b)`, never v2's `Host(a, b)`, which the CRD accepts and
Traefik v3 routes nowhere. */}}
{{- define "common.ingressRoute" -}}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .name }}
  {{- if or .annotations .public }}
  annotations:
    {{- if .public }}
    external-dns.alpha.kubernetes.io/target: tunnel.jterrazz.com
    {{- end }}
    {{- with .annotations }}
    {{- . | nindent 4 }}
    {{- end }}
  {{- end }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  entryPoints:
    - {{ if .public }}tunnel{{ else }}websecure{{ end }}
  routes:
    - match: {{ .match }}
      kind: Rule
      {{- with .middlewares }}
      middlewares:
        {{- range . }}
        - name: {{ .name }}
        {{- if .namespace }}
          namespace: {{ .namespace }}
        {{- end }}
        {{- end }}
      {{- end }}
      services:
        - name: {{ .serviceName }}
          port: {{ .servicePort }}
  {{- if not .public }}
  tls: {}
  {{- end }}
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
