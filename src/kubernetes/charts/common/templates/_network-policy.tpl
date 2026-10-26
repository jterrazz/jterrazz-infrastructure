{{/* The peer vocabulary both charts speak (platform/README.md, "Peers").
hazard: ports are pod ports, never Service ports; hostNetwork clients match only an ipBlock.
Input dict: name, labels and podSelector (rendered lines, "" for the namespace), policyTypes,
ingress ({ from, ports? }), egress ({ to, ports? }). A bare port is TCP. */}}
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

{{/* Input dict: direction ("from" or "to"), rule. */}}
{{- define "common.networkPolicy.rule" -}}
{{- $dir := .direction -}}
{{- $rule := .rule -}}
{{- if not (hasKey $rule $dir) -}}
{{- fail (printf "network rule is missing its `%s:` peer, got %v" $dir $rule) -}}
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
{{- /* invariant: also the tailnet, OrbStack's machine network and link-local. */}}
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8
          - 172.16.0.0/12
          - 192.168.0.0/16
          - 100.64.0.0/10
          - 198.19.0.0/16
          - 169.254.0.0/16
{{- else if eq $peer "anywhere" }}
    - ipBlock:
        cidr: 0.0.0.0/0
{{- else if hasPrefix "namespace:" $peer }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ trimPrefix "namespace:" $peer }}
{{- else if hasPrefix "namespace-label:" $peer }}
{{- /* invariant: the namespace's label, which only the namespace's owner sets: a pod label
       would let any workload in the cluster claim a client's identity (ADR-029). */}}
{{- $pair := splitn "=" 2 (trimPrefix "namespace-label:" $peer) }}
    - namespaceSelector:
        matchExpressions:
          - key: {{ $pair._0 }}
            operator: In
            values:
              {{- range splitList "," $pair._1 }}
              - {{ . | quote }}
              {{- end }}
{{- else if hasPrefix "pods:" $peer }}
{{- $pair := splitn "=" 2 (trimPrefix "pods:" $peer) }}
    - podSelector:
        matchLabels:
          {{ $pair._0 }}: {{ $pair._1 | quote }}
{{- else }}
{{- fail (printf "network: unknown peer %q (valid: traefik, any-namespace, internet, anywhere, namespace:<ns>, pods:<key>=<value>, namespace-label:<key>=<value>[,<value>...])" $peer) }}
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
