{{/*
One NetworkPolicy, from a peer vocabulary both charts speak.

WHY A VOCABULARY AND NOT RAW RULES: NetworkPolicy has two traps that a
hand-written rule pays for every time, and neither is visible in the YAML.

  1. Policies are evaluated AFTER kube-proxy's DNAT, so every port is a
     containerPort, NEVER a Service port. A rule naming Traefik's 443 (pod
     8443) or Grafana's 80 (pod 3000) applies to nothing and the traffic is
     dropped by the default-deny with nothing logged.
  2. hostNetwork clients are not pods. cloudflared and the apiserver arrive as
     the node address, so only an ipBlock matches them; a podSelector-only rule
     silently excludes them.

The vocabulary cannot fix (1) — the caller still has to name a pod port — but
it does make the ipBlock shapes in (2) a single spelling instead of five.

PEERS (the `from:` of an ingress rule, the `to:` of an egress rule):

  traefik                    the kube-system namespace, where k3s runs Traefik.
  namespace:<ns>             one namespace, by its kubernetes.io/metadata.name.
  any-namespace              every namespace. DNS egress needs it: a pod
                             resolves before it can know which namespace
                             answered.
  any-namespace-pods:<k>=<v> pods carrying a label, in ANY namespace. The
                             server side of the app chart's platformServices
                             catalogue: a consumer opts in by stamping the
                             label, so a new consumer needs zero edit here.
  pods:<k>=<v>               pods carrying a label IN THE POLICY'S OWN
                             namespace — a podSelector with no
                             namespaceSelector beside it, which is what
                             NetworkPolicy reads as "here". The tightest peer
                             there is, and the one an unauthenticated
                             datastore wants: `any-namespace-pods:` with the
                             same label would admit a pod of that name from
                             any namespace in the cluster.
  internet                   0.0.0.0/0 EXCEPT RFC1918 — no lateral reach into
                             the node LAN, another cluster's pod/service CIDR,
                             or the apiserver.
  anywhere                   0.0.0.0/0, no exception. Deliberately distinct
                             from `internet`: on this cluster the apiserver is
                             RFC1918 twice over (the `kubernetes` ClusterIP
                             10.43.0.1:443 DNATs to the node's own
                             192.168.x.x:6443), so anything that must reach it
                             — or must scrape an annotation-driven target set
                             that no static list can enumerate — needs this one.
                             Never "tidy" an `anywhere` into an `internet`.

PORTS: a bare number is TCP (the Kubernetes default, left unwritten so the
rendered object matches what the API server stores). `<port>/<PROTO>` spells a
protocol out; that is what UDP needs.

Input dict:
  name          metadata.name
  labels        rendered label lines (a STRING — each chart keeps its own order)
  podSelector   rendered matchLabels lines, or "" for the whole namespace
  policyTypes   list of "Ingress" / "Egress"
  ingress       list of { from: <peer>, ports?: [...] }
  egress        list of { to:   <peer>, ports?: [...] }

A policyType with no matching rules is a DENY for that direction — which is a
real, useful thing to declare, so it is not an error here.
*/}}
{{- define "common.networkPolicy" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  {{- if .podSelector }}
  podSelector:
    matchLabels:
      {{- .podSelector | nindent 6 }}
  {{- else }}
  podSelector: {}
  {{- end }}
  policyTypes:
    {{- range .policyTypes }}
    - {{ . }}
    {{- end }}
  {{- if .ingress }}
  ingress:
    {{- range .ingress }}
    {{- include "common.networkPolicy.rule" (dict "direction" "from" "rule" .) | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- if .egress }}
  egress:
    {{- range .egress }}
    {{- include "common.networkPolicy.rule" (dict "direction" "to" "rule" .) | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end -}}

{{/*
Lower ONE rule of that vocabulary. Input dict: direction ("from"|"to"), rule.
Output starts at column 0; the caller indents it.
*/}}
{{- define "common.networkPolicy.rule" -}}
{{- $dir := .direction -}}
{{- $rule := .rule -}}
{{- if not (hasKey $rule $dir) -}}
{{- fail (printf "network rule is missing its `%s:` peer — got %v" $dir $rule) -}}
{{- end -}}
{{- $peer := index $rule $dir | toString -}}
- {{ $dir }}:
{{- if eq $peer "traefik" }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
{{- else if eq $peer "any-namespace" }}
    - namespaceSelector: {}
{{- else if eq $peer "internet" }}
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8
          - 172.16.0.0/12
          - 192.168.0.0/16
{{- else if eq $peer "anywhere" }}
    - ipBlock:
        cidr: 0.0.0.0/0
{{- else if hasPrefix "namespace:" $peer }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ trimPrefix "namespace:" $peer }}
{{- else if hasPrefix "any-namespace-pods:" $peer }}
{{- $pair := splitn "=" 2 (trimPrefix "any-namespace-pods:" $peer) }}
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          {{ $pair._0 }}: {{ $pair._1 | quote }}
{{- else if hasPrefix "pods:" $peer }}
{{- $pair := splitn "=" 2 (trimPrefix "pods:" $peer) }}
    - podSelector:
        matchLabels:
          {{ $pair._0 }}: {{ $pair._1 | quote }}
{{- else }}
{{- fail (printf "network: unknown peer %q (valid: traefik, any-namespace, internet, anywhere, namespace:<ns>, pods:<key>=<value>, any-namespace-pods:<key>=<value>)" $peer) }}
{{- end }}
{{- if $rule.ports }}
  ports:
  {{- range $port := $rule.ports }}
  {{- $spec := $port | toString }}
  {{- if contains "/" $spec }}
    - port: {{ index (splitList "/" $spec) 0 }}
      protocol: {{ index (splitList "/" $spec) 1 }}
  {{- else }}
    - port: {{ $spec }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end -}}
