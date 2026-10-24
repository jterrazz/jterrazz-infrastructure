{{/* The smoke contract the platform contract (harness/specs/api) reads off every
IngressRoute: path (after any stripPrefix), expect (comma-separated codes, never 000 or a
5xx), location and method (optional), or probe "false" to opt out.
Input dict: probe, path, expect, location, method. */}}
{{- define "common.smokeAnnotations" -}}
{{- if and (hasKey . "probe") (not .probe) -}}
smoke.jterrazz.com/probe: "false"
{{- else -}}
smoke.jterrazz.com/path: {{ .path | toString | quote }}
smoke.jterrazz.com/expect: {{ .expect | toString | quote }}
{{- if .location }}
smoke.jterrazz.com/location: {{ .location | toString | quote }}
{{- end }}
{{- if .method }}
smoke.jterrazz.com/method: {{ .method | toString | quote }}
{{- end }}
{{- end -}}
{{- end -}}
