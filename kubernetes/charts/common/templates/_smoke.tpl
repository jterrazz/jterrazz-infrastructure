{{/*
THE SMOKE CONTRACT — what scripts/smoke.sh probes, written on the route itself.

smoke.sh holds no table of hostnames or status codes any more: it lists every
IngressRoute in the cluster and reads these annotations off each one. The
expectation therefore ships with the thing it describes, and a route that moves,
appears or disappears takes its check with it.

  smoke.jterrazz.com/path      the EXTERNALLY VISIBLE path to probe, i.e. after
                               whatever stripPrefix the route attaches.
  smoke.jterrazz.com/expect    accepted HTTP status codes, comma-separated. Keep
                               it as narrow as the service genuinely allows —
                               the point of the probe is that a 502/503/000 can
                               never read as "fine". Never 000, never a 5xx.
  smoke.jterrazz.com/location  optional; asserts the Location header. A 301 to
                               the WRONG host is still a 301, so every redirect
                               names its target.
  smoke.jterrazz.com/probe     "false" opts the route out entirely. Only written
                               when there IS no derivable probe — an unannotated
                               route is probed with the fallback (`/`, 200) and
                               reported, which is not the same claim.

smoke.jterrazz.com/method (default GET) is also read by smoke.sh but emitted by
no chart: the one route that needs it is OpenPanel's hand-written POST-only
ingest (kubernetes/services/openpanel/ingress.yaml).

Input dict: probe (optional bool — pass false to opt out), path, expect,
location (optional). Emits annotation LINES at column 0; the caller indents.
*/}}
{{- define "common.smokeAnnotations" -}}
{{- if and (hasKey . "probe") (not .probe) -}}
smoke.jterrazz.com/probe: "false"
{{- else -}}
smoke.jterrazz.com/path: {{ .path | toString | quote }}
smoke.jterrazz.com/expect: {{ .expect | toString | quote }}
{{- if .location }}
smoke.jterrazz.com/location: {{ .location | toString | quote }}
{{- end }}
{{- end -}}
{{- end -}}
