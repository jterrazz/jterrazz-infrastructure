{{- define "app.name" -}}
{{- .Values.metadata.name | required "metadata.name is required" -}}
{{- end -}}

{{/*
THE resolver: the fully-resolved `spec` for the environment being rendered.
Every template starts with

  {{- $spec := fromYaml (include "app.merged" .) -}}

and then reads plain keys ($spec.port, $spec.env, $spec.resources.memory, …).
An environment may override ANY spec key. Merge rules (sprig mergeOverwrite,
spec first, environment second):

  * scalars  — environment wins, else spec, else the caller's `| default`.
  * maps     — DEEP merged, environment wins per key. `resources: {memory: …}`
               in an environment keeps the base `cpu`; `env:` / `secrets:`
               merge key-by-key with THE ENVIRONMENT WINNING on a collision.
  * lists    — REPLACED wholesale. An environment's `ingress` or
               `platformServices` list fully supersedes spec's, deliberately:
               a half-merged list of network surfaces is unreadable.

deepCopy because mergeOverwrite mutates its first argument, and .Values is
shared across every template in the render.
*/}}
{{- define "app.merged" -}}
{{- $env := .Values.environment -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- mergeOverwrite (deepCopy .Values.spec) (deepCopy $envConfig) | toYaml -}}
{{- end -}}

{{/*
Nothing renders for an environment that isn't declared under `environments:` —
a typo'd `--set environment=prd` produces an empty release rather than an
error. Turning that into a hard failure is a breaking change owned by a later
coordinated release; deliberately NOT done here.
*/}}
{{- define "app.envExists" -}}
{{- $env := .Values.environment -}}
{{- if and $env (hasKey .Values.environments $env) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Resolved ingress list plus the one check a values file can't express: entries
are { host, path?, public?, stripPrefix? } objects. Returns YAML; consume via
fromYamlArray.
*/}}
{{- define "app.ingressList" -}}
{{- $list := (fromYaml (include "app.merged" .)).ingress -}}
{{- if not (kindIs "slice" $list) -}}
{{- fail "ingress must be a list of { host, path?, public? } entries. The single-object form was removed in chart 1.17.0 — migrate to a one-element list." -}}
{{- end -}}
{{- $list | toYaml -}}
{{- end -}}

{{- define "app.image" -}}
{{- $spec := fromYaml (include "app.merged" .) -}}
{{- if $spec.image -}}
{{- $spec.image -}}
{{- else -}}
registry.internal.jterrazz.com/{{ include "app.name" . }}:latest
{{- end -}}
{{- end -}}

{{/*
Parse a memory quantity to an integer number of MiB. Returns "" for anything
that is not `<n>Mi` or `<n>Gi` — both callers treat that as "can't reason
about this, leave it alone".
*/}}
{{- define "app.memMi" -}}
{{- $mem := . | toString -}}
{{- if hasSuffix "Mi" $mem -}}
{{- trimSuffix "Mi" $mem | int -}}
{{- else if hasSuffix "Gi" $mem -}}
{{- mul (trimSuffix "Gi" $mem | int) 1024 -}}
{{- end -}}
{{- end -}}

{{/*
Memory limit — explicit `resources.memoryLimit`, else 2x the request. A
derived limit is always emitted in Mi; a request in neither Mi nor Gi passes
through unchanged.
*/}}
{{- define "app.memoryLimit" -}}
{{- $resources := (fromYaml (include "app.merged" .)).resources -}}
{{- $memLimit := $resources.memoryLimit -}}
{{- if $memLimit -}}
{{- $memLimit -}}
{{- else -}}
{{- $mem := $resources.memory -}}
{{- $mi := include "app.memMi" $mem -}}
{{- if $mi -}}
{{- printf "%dMi" (mul ($mi | int) 2) -}}
{{- else -}}
{{- $mem -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Node.js V8 old-space cap (MiB) ≈ 75% of the memory *request*, and ONLY at or
above a 512Mi request: below that floor a derived cap (96MB for a 128Mi Next.js
service) starves SSR boot and crash-loops the pod. Returns "" there, and for a
non-Mi/Gi request, so the caller skips injection entirely.
*/}}
{{- define "app.nodeMaxOldSpace" -}}
{{- $resources := (fromYaml (include "app.merged" .)).resources -}}
{{- $mem := $resources.memory -}}
{{- $reqMi := include "app.memMi" $mem | default "0" | int -}}
{{- if ge $reqMi 512 -}}
{{- div (mul $reqMi 3) 4 -}}
{{- end -}}
{{- end -}}

{{- define "app.infisicalEnv" -}}
{{- (fromYaml (include "app.merged" .)).secretsEnv | default .Values.environment -}}
{{- end -}}

{{/* signews.jterrazz.com -> signews-jterrazz-com */}}
{{- define "app.hostSlug" -}}
{{- . | lower | replace "." "-" -}}
{{- end -}}

{{- define "app.secretsName" -}}
{{ include "app.name" . }}-secrets
{{- end -}}

{{/*
Single source of truth for the in-cluster platform services an app can opt
into via `spec.platformServices: [ ... ]`. Declaring a service wires the whole
bundle from this catalog: env injection (client side) + egress NetworkPolicy +
(for a service that IS a catalog target, e.g. gateway-intelligence) the
server-side ingress rule via a pod label selector.

Per entry:
  env         map of env var name -> value injected into opted-in consumers.
              A user-set env of the same name always wins (see deployment.yaml).
  egress      { namespace, ports[] } — the consumer's egress NetworkPolicy hole.
              ports are the POD ports (NOT the Service port). Namespace is
              pinned (gateway-intelligence only exists in prod).
  clientLabel (optional) pod label the consumer stamps on its own pods; the
              target service's chart-rendered ingress rule selects on it, so a
              new consumer needs ZERO edit on the target.

OTEL_EXPORTER_OTLP_ENDPOINT keeps its spec-mandated name (the OTel SDK owns
that contract — the one naming exception). gateway-intelligence carries no
secret: it enforces no client API key, so consumers pass the non-secret
placeholder the OpenAI SDK's non-empty-string check demands.
*/}}
{{- define "app.platformCatalog" -}}
otel-collector:
  env:
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.platform-telemetry:4318"
  egress:
    namespace: platform-telemetry
    ports:
      - 4317
      - 4318
gateway-intelligence:
  env:
    GATEWAY_INTELLIGENCE_BASE_URL: "http://gateway-intelligence.prod-gateway-intelligence.svc.cluster.local/v1"
  egress:
    namespace: prod-gateway-intelligence
    ports:
      - 8317
  clientLabel: platform-client.jterrazz.com/gateway-intelligence
{{- end -}}

{{/*
Validated opt-in platform services for the current environment. Fails fast on
an unknown name (typo protection) here, in the single accessor every consumer
(env injection, client labels, netpol) already calls, so a bad name can never
render a silently-broken manifest. Returns a YAML list (fromYamlArray).
*/}}
{{- define "app.platformServices" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- $services := (fromYaml (include "app.merged" .)).platformServices -}}
{{- range $svc := $services -}}
{{- if not (hasKey $catalog $svc) -}}
{{- fail (printf "spec.platformServices: unknown service %q (valid: %s)" $svc (keys $catalog | sortAlpha | join ", ")) -}}
{{- end -}}
{{- end -}}
{{- $services | toYaml -}}
{{- end -}}

{{- define "app.platformEnv" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- $out := dict -}}
{{- range $svc := (fromYamlArray (include "app.platformServices" .)) -}}
{{- if hasKey $catalog $svc -}}
{{- $entry := index $catalog $svc -}}
{{- if $entry.env -}}
{{- range $k, $v := $entry.env -}}
{{- $_ := set $out $k $v -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{/*
Client labels (label -> "true") this consumer stamps on its own pods, so the
target platform service's ingress NetworkPolicy selects it. Empty for a
catalog entry with no clientLabel.
*/}}
{{- define "app.platformClientLabels" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- $out := dict -}}
{{- range $svc := (fromYamlArray (include "app.platformServices" .)) -}}
{{- if hasKey $catalog $svc -}}
{{- $entry := index $catalog $svc -}}
{{- if $entry.clientLabel -}}
{{- $_ := set $out $entry.clientLabel "true" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{- define "app.labels" -}}
app: {{ include "app.name" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app: {{ include "app.name" . }}
environment: {{ .Values.environment }}
{{- end -}}
