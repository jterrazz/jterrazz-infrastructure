{{/*
Traefik routing — the IngressRoute and the two Middlewares that hang off it.
Both charts render routes; only their NAMES and their match expressions differ,
so every name is an input and this file invents none.
*/}}

{{/*
`access` -> the ONE Traefik ipAllowList middleware for a route, or "" for none.

NEVER chain the two allow-lists: Traefik ANDs chained ipAllowLists, so the
source would have to satisfy BOTH and chaining allows strictly LESS, not more.
cluster-internal-access is already a strict superset of private-access.

  private          tailnet humans only. The default, and the narrow one — a
                   values file that forgets the key gets tailnet-only.
  cluster-internal tailnet humans PLUS the pod/service CIDRs and the node. For
                   routes something inside the cluster must also reach
                   (registry image pulls, openpanel SSR).
  public           no ipAllowList. The route is still behind the rate-limit /
                   compress / security-headers chain the websecure entrypoint
                   attaches globally.

Input: the access string. Output: the middleware name, or "".
*/}}
{{- define "common.accessMiddleware" -}}
{{- $access := . | default "private" -}}
{{- if eq $access "private" -}}
private-access
{{- else if eq $access "cluster-internal" -}}
cluster-internal-access
{{- else if ne $access "public" -}}
{{- fail (printf "access must be one of private|cluster-internal|public, got %q" $access) -}}
{{- end -}}
{{- end -}}

{{/*
One IngressRoute on the websecure entrypoint.

Input dict:
  name         metadata.name
  labels       rendered label lines (a STRING, so each chart keeps its own
               label order rather than toYaml's alphabetical one)
  match        the whole Traefik match expression. The caller builds it: the
               app chart's Host() && PathPrefix(), platform-service's
               Host(a) || Host(b) — never the v2 Host(a, b), which the CRD
               schema accepts and Traefik v3 then fails to build a router for
               (404 on every name, nothing in `kubectl get` to say so).
  middlewares  list of { name, namespace? }, in attachment order
  serviceName  / servicePort  the backend
  tlsSecret    the Certificate's secret
  annotations  rendered annotation lines (a STRING), or "" — the smoke contract
               (common.smokeAnnotations) is the only thing that writes them
*/}}
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

{{/*
stripPrefix Middleware. Input dict: name, labels, prefix.
*/}}
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

{{/*
Canonical-host redirect Middleware. Input dict: name, labels, host, replacement.

The regex is anchored on the SCHEME too: Traefik matches against the full URL,
so an unanchored pattern would also rewrite a request whose PATH happens to
contain the host. 301, not 302 — this host is not coming back, and a permanent
redirect is what moves search rankings to the canonical host.
*/}}
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
