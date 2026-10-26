{{/* The smoke contract the platform contract (specs/specs/api) reads off every
IngressRoute: path (after any stripPrefix), expect (comma-separated codes, never 000 or a
5xx), location and method (optional), or probe "false" to opt out.
Input dict: probe, path, expect, location, method. */}}
{{- define "common.smokeAnnotations" -}}
{{- if and (hasKey . "probe") (not .probe) -}}
studio.jterrazz.com/smoke-probe: "false"
{{- else -}}
studio.jterrazz.com/smoke-path: {{ .path | toString | quote }}
studio.jterrazz.com/smoke-expect: {{ .expect | toString | quote }}
{{- if .location }}
studio.jterrazz.com/smoke-location: {{ .location | toString | quote }}
{{- end }}
{{- if .method }}
studio.jterrazz.com/smoke-method: {{ .method | toString | quote }}
{{- end }}
{{- end -}}
{{- end -}}
