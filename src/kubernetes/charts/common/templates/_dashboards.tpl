{{/* Input dict: owner (the app's name, or `studio-infrastructure` for what this repository runs), dashboards
(file name -> Grafana dashboard JSON), field (how an error names the map), labels (rendered lines),
configMapPrefix, and workload (optional: namespace and container, for a link to the generic
`studio-infrastructure / Workload`, so an app's dashboards never copy its CPU, memory and log panels). One ConfigMap per dashboard, for the sidecar to file under the owner's folder.
invariant: the file name is the dashboard's kind (`service`, `business`, or a subsystem an
investigation keeps returning to), and the identity is derived from it, never written: uid
`<owner>-<kind>`, title `<owner> / <Kind>`, tags `[<owner>, <kind>]`, a link to every dashboard of
the owner. What the author writes is the panels (ADR-027).
hazard: a catch-all kind (`overview`, `misc`, `general`, `main`) names no audience and no question,
which is how one dashboard turns into everything; the render refuses it. */}}
{{- define "common.dashboards" -}}
{{- $owner := .owner -}}
{{- $field := .field -}}
{{- range $kind, $json := .dashboards | default dict }}
{{- if not (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" $kind) -}}
{{- fail (printf "%s.%s: a dashboard file is named by its kind in kebab-case (service, business, or a subsystem)" $field $kind) -}}
{{- end -}}
{{- if has $kind (list "overview" "misc" "general" "main" "dashboard") -}}
{{- fail (printf "%s.%s: %q names no audience; a dashboard is `service` (is it broken, and where), `business` (does it produce what it should), or a subsystem worth its own investigation" $field $kind $kind) -}}
{{- end -}}
{{- $uid := printf "%s-%s" $owner $kind -}}
{{- if gt (len $uid) 40 -}}
{{- fail (printf "%s.%s: the derived uid %q is %d characters; Grafana caps a uid at 40" $field $kind $uid (len $uid)) -}}
{{- end -}}
{{- $doc := fromJson (toString $json) -}}
{{- if hasKey $doc "Error" -}}
{{- fail (printf "%s.%s: not a JSON dashboard: %s" $field $kind $doc.Error) -}}
{{- end -}}
{{- $_ := unset $doc "id" -}}
{{- $_ := set $doc "uid" $uid -}}
{{- $_ := set $doc "title" (printf "%s / %s" $owner (title (replace "-" " " $kind))) -}}
{{- $_ := set $doc "tags" (list $owner $kind) -}}
{{- $links := list (dict "type" "dashboards" "tags" (list $owner) "asDropdown" false "includeVars" true "keepTime" true "title" $owner) -}}
{{- with $.workload -}}
{{- $links = append $links (dict "type" "link" "title" "workload" "icon" "dashboard" "keepTime" true "targetBlank" false
      "url" (printf "/d/studio-infrastructure-workload?var-namespace=%s&var-container=%s" .namespace .container)) -}}
{{- end -}}
{{- $_ := set $doc "links" $links }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $.configMapPrefix }}{{ $kind }}
  labels:
    {{- $.labels | nindent 4 }}
    grafana_dashboard: "1"
  annotations:
    grafana_folder: {{ $owner }}
data:
  {{ $uid }}.json: |
    {{- toPrettyJson $doc | nindent 4 }}
{{- end }}
{{- end -}}
