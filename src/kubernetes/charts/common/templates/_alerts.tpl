{{/* Input dict: alerts (name -> Grafana provisioning document), field (how the error names the
map). Returns the map, every document checked first: one file Grafana refuses stops the alerting
reload for every app, so a bad one fails the render instead.
invariant: no rule sets `execErrState: OK`, which keeps a broken query green forever; unset,
Grafana's `Error` fires on it. */}}
{{- define "common.alerts" -}}
{{- $field := .field -}}
{{- $uids := dict -}}
{{- range $name, $payload := .alerts | default dict -}}
{{- $doc := fromYaml (toString $payload) -}}
{{- if or (hasKey $doc "Error") (ne (toString $doc.apiVersion) "1") -}}
{{- fail (printf "%s.%s: the payload must be a Grafana provisioning document with `apiVersion: 1`" $field $name) -}}
{{- end -}}
{{- if not (kindIs "slice" $doc.groups) -}}
{{- fail (printf "%s.%s: `groups` must be a list of rule groups" $field $name) -}}
{{- end -}}
{{- range $gi, $group := $doc.groups -}}
{{- if not (and (kindIs "map" $group) $group.name $group.folder) -}}
{{- fail (printf "%s.%s: group %d must name both `name` and `folder`" $field $name $gi) -}}
{{- end -}}
{{- range $ri, $rule := $group.rules | default list -}}
{{- $uid := "" -}}
{{- if kindIs "map" $rule -}}{{- $uid = toString ($rule.uid | default "") -}}{{- end -}}
{{- if not $uid -}}
{{- fail (printf "%s.%s: rule %d of group %q has no `uid`" $field $name $ri $group.name) -}}
{{- end -}}
{{- if gt (len $uid) 40 -}}
{{- fail (printf "%s.%s: rule uid %q is %d characters; Grafana caps a uid at 40 and rejects the whole alerting reload, for every app, when one exceeds it" $field $name $uid (len $uid)) -}}
{{- end -}}
{{- if not (regexMatch "^[a-zA-Z0-9_-]+$" $uid) -}}
{{- fail (printf "%s.%s: rule uid %q may hold only letters, digits, `-` and `_`" $field $name $uid) -}}
{{- end -}}
{{- if hasKey $uids $uid -}}
{{- fail (printf "%s.%s: rule uid %q is already used by %s.%s" $field $name $uid $field (get $uids $uid)) -}}
{{- end -}}
{{- if eq (toString ($rule.execErrState | default "")) "OK" -}}
{{- fail (printf "%s.%s: rule %q sets `execErrState: OK`, which keeps a broken query green; leave it unset" $field $name $uid) -}}
{{- end -}}
{{- $_ := set $uids $uid $name -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- .alerts | default dict | toYaml -}}
{{- end -}}

{{/* Input dict: name, labels (rendered lines), alerts (the checked map). One ConfigMap for every
document, so a renamed file leaves no orphan behind still provisioning its rules. */}}
{{- define "common.alertsConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
    grafana_alert: "1"
data:
  {{- range $name, $rules := .alerts }}
  {{ $name }}.yaml: |
    {{- $rules | nindent 4 }}
  {{- end }}
{{- end -}}
