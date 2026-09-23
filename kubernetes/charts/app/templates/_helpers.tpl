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
through unchanged. `app.memoryLimitOf` takes the resources map itself, so a
cron job's own `resources` derive their limit by the same rule.
*/}}
{{- define "app.memoryLimit" -}}
{{- include "app.memoryLimitOf" (fromYaml (include "app.merged" .)).resources -}}
{{- end -}}

{{- define "app.memoryLimitOf" -}}
{{- $resources := . -}}
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
`app.nodeMaxOldSpaceOf` takes the resources map itself, so a cron job's heap cap
follows its OWN request rather than the app's.
*/}}
{{- define "app.nodeMaxOldSpace" -}}
{{- include "app.nodeMaxOldSpaceOf" (fromYaml (include "app.merged" .)).resources -}}
{{- end -}}

{{- define "app.nodeMaxOldSpaceOf" -}}
{{- $mem := .memory -}}
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
              A user-set env of the same name always wins (app.containerEnv).
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

{{/*
The probe action shared by all three probes — httpGet by default, and the two
alternatives a datastore needs. Exactly one is emitted, in this order:

  health.exec  [cmd, …]  an exec probe. Postgres answers `pg_isready`, Redis
                         `redis-cli ping`; neither speaks HTTP at all.
  health.tcp   true      a tcpSocket probe on spec.port. For a server that
                         speaks its own protocol and whose CLIENT is too heavy
                         to run per probe — mongosh's cold start alone exceeds
                         the probe timeout, which crash-loops a healthy mongod.
  health.path  <path>    the default: httpGet on spec.port.

Emits YAML lines at column 0; the caller nindents them.
*/}}
{{- define "app.probe" -}}
{{- $spec := fromYaml (include "app.merged" .) -}}
{{- $health := $spec.health -}}
{{- if $health.exec -}}
exec:
  command:
    {{- range $health.exec }}
    - {{ . | quote }}
    {{- end }}
{{- else if $health.tcp -}}
tcpSocket:
  port: {{ $spec.port }}
{{- else -}}
httpGet:
  path: {{ $health.path }}
  port: {{ $spec.port }}
{{- end -}}
{{- end -}}

{{/*
"true" when the image comes from OUR registry. Two things follow from it and
from nothing else: the imagePullSecret (the credential authenticates that
registry alone, and naming a Secret absent from the namespace earns a warning
event on every pod start) and `imagePullPolicy: Always` (our tags are mutable;
a third-party pinned tag is better left on Kubernetes' default, which also
keeps a pod restart off Docker Hub's anonymous pull quota).
*/}}
{{- define "app.privateImage" -}}
{{- if hasPrefix (printf "%s/" .Values.registry.server) (include "app.image" .) -}}
true
{{- end -}}
{{- end -}}

{{/*
Where one `spec.configFiles` entry is mounted. A plain string value is content,
mounted at /app/<filename> — the shape every app repo uses. A `{ path, content }`
map puts the same file at an absolute path the IMAGE dictates
(/etc/clickhouse-server/config.d/…, /docker-entrypoint-initdb.d/…), which is
the only reason the map form exists.

Input dict: filename, file.
*/}}
{{- define "app.configFilePath" -}}
{{- if kindIs "map" .file -}}
{{- .file.path | required (printf "spec.configFiles.%s is a map, so it must carry `path:` (and `content:`)" .filename) -}}
{{- else -}}
/app/{{ .filename }}
{{- end -}}
{{- end -}}

{{/*
The CONTENT of one `spec.configFiles` entry — the value itself for the string
form, `.content` for the map form. Input dict: filename, file.
*/}}
{{- define "app.configFileContent" -}}
{{- if kindIs "map" .file -}}
{{- .file.content | required (printf "spec.configFiles.%s is a map, so it must carry `content:` (and `path:`)" .filename) -}}
{{- else -}}
{{- .file -}}
{{- end -}}
{{- end -}}

{{/*
The container securityContext: the chart's hardened defaults with
`spec.securityContext` merged OVER them. readOnlyRootFilesystem is deliberately
NOT among the defaults: every app here is a Next.js or Node service that writes
caches at runtime, and setting it would crash-loop them. runAsNonRoot is
dropped for an explicit spec.runAsRoot, which it would contradict. deepCopy
because mergeOverwrite mutates its first argument. Returns YAML.
*/}}
{{- define "app.containerSecurityContext" -}}
{{- $spec := fromYaml (include "app.merged" .) -}}
{{- $secDefaults := dict
      "allowPrivilegeEscalation" false
      "capabilities" (dict "drop" (list "ALL"))
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- if not $spec.runAsRoot -}}
{{- $_ := set $secDefaults "runAsNonRoot" true -}}
{{- end -}}
{{- toYaml (mergeOverwrite (deepCopy $secDefaults) $spec.securityContext) -}}
{{- end -}}

{{/*
The pod-level securityContext block, or nothing at all for spec.runAsRoot.
*/}}
{{- define "app.podSecurityContext" -}}
{{- if not (fromYaml (include "app.merged" .)).runAsRoot -}}
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
{{- end -}}
{{- end -}}

{{/*
The container `env:` list, shared by the Deployment and every cron job so a
job runs with exactly the environment the app does — the same secrets, the
same platform endpoints. Input dict: ctx (the root context), resources (the
map the NODE_OPTIONS heap cap derives from: the app's, or a job's own).
Emits list items at column 0.
*/}}
{{- define "app.containerEnv" -}}
{{- $ctx := .ctx -}}
{{- $spec := fromYaml (include "app.merged" $ctx) -}}
{{- $envVars := $spec.env -}}
{{- $secrets := $spec.secrets -}}
{{- $platformEnv := fromYaml (include "app.platformEnv" $ctx) -}}
- name: PORT
  value: {{ $spec.port | quote }}
{{- range $key, $value := $envVars }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- if not (hasKey $envVars "OTEL_SERVICE_NAME") }}
- name: OTEL_SERVICE_NAME
  value: {{ include "app.name" $ctx }}
{{- end }}
{{- /* Both spellings: `deployment.environment` is what the collector's
       Langfuse filter, the remote-write label (deployment_environment) and
       @jterrazz/telemetry read; `deployment.environment.name` is the current
       semconv, which Langfuse maps to its Environment field. */}}
{{- if not (hasKey $envVars "OTEL_RESOURCE_ATTRIBUTES") }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "deployment.environment={{ $ctx.Values.environment }},deployment.environment.name={{ $ctx.Values.environment }}"
{{- end }}
{{- /* Opt-in platform-service env (spec.platformServices → the catalog
       above). An app must declare `otel-collector` for telemetry to flow —
       declaring it is also what opens the egress hole. A user-set env wins. */}}
{{- range $key, $value := $platformEnv }}
{{- if not (hasKey $envVars $key) }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- /* Default Node.js heap cap ≈ 75% of the memory request. Skipped entirely
       if the app sets its own NODE_OPTIONS. Harmless on non-Node runtimes
       (the var is ignored). */}}
{{- $nodeHeap := include "app.nodeMaxOldSpaceOf" .resources }}
{{- if and $nodeHeap (not (hasKey $envVars "NODE_OPTIONS")) }}
- name: NODE_OPTIONS
  value: "--max-old-space-size={{ $nodeHeap }}"
{{- end }}
{{- if $secrets.env }}
{{- range $secrets.env }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ include "app.secretsName" $ctx }}
      key: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The container `volumeMounts:` / pod `volumes:` lists. Input dict: ctx, storage
(whether the data volume is part of it — always for the Deployment when
spec.storage is set, only on request for a cron job). Emit list items; callers
`trim` and indent them.
*/}}
{{- define "app.volumeMounts" -}}
{{- $spec := fromYaml (include "app.merged" .ctx) -}}
{{- if .storage }}
- name: data
  mountPath: {{ $spec.storage.mountPath }}
{{- end }}
{{- range $filename, $file := $spec.configFiles }}
- name: config
  mountPath: {{ include "app.configFilePath" (dict "filename" $filename "file" $file) }}
  subPath: {{ $filename }}
  readOnly: true
{{- end }}
{{- range $spec.secretMounts }}
- name: {{ .secretName }}
  mountPath: {{ .mountPath }}
  readOnly: true
{{- end }}
{{- end -}}

{{- define "app.volumes" -}}
{{- $ctx := .ctx -}}
{{- $spec := fromYaml (include "app.merged" $ctx) -}}
{{- if .storage }}
- name: data
  persistentVolumeClaim:
    claimName: {{ $spec.storage.claimName | default (printf "%s-data" (include "app.name" $ctx)) }}
{{- end }}
{{- if $spec.configFiles }}
- name: config
  configMap:
    name: {{ include "app.name" $ctx }}-config
{{- end }}
{{- range $spec.secretMounts }}
- name: {{ .secretName }}
  secret:
    secretName: {{ .secretName }}
{{- end }}
{{- end -}}

{{/*
The validated `spec.cronJobs` map (name -> job), for the environment being
rendered. Every check a bad entry could otherwise turn into a silently wrong
object fails the render here instead:

  * the name must be a DNS-1123 label, and `<app>-<name>` at most 52
    characters — the CronJob controller appends an 11-character suffix to
    name each Job, and a Job name is capped at 63;
  * `schedule` is required;
  * `command` is required and non-empty. The app's own entrypoint is its
    server, and a server started on a schedule never exits: it would run
    until activeDeadlineSeconds killed it, every time;
  * `storage: true` needs spec.storage, or there is no volume to mount.

Returns YAML; consume via fromYaml.
*/}}
{{- define "app.cronJobs" -}}
{{- $spec := fromYaml (include "app.merged" .) -}}
{{- $app := include "app.name" . -}}
{{- $jobs := $spec.cronJobs | default dict -}}
{{- range $name, $job := $jobs -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail (printf "spec.cronJobs.%s: the name must be lowercase letters, digits and dashes (a DNS-1123 label)" $name) -}}
{{- end -}}
{{- $full := printf "%s-%s" $app $name -}}
{{- if gt (len $full) 52 -}}
{{- fail (printf "spec.cronJobs.%s: %q is %d characters; a CronJob name may have at most 52, because each Job it creates appends an 11-character suffix" $name $full (len $full)) -}}
{{- end -}}
{{- if not $job.schedule -}}
{{- fail (printf "spec.cronJobs.%s: `schedule` is required (a cron expression, evaluated in `timeZone`, default Etc/UTC)" $name) -}}
{{- end -}}
{{- if not $job.command -}}
{{- fail (printf "spec.cronJobs.%s: `command` is required — without it the job would start the app's own server, which never exits" $name) -}}
{{- end -}}
{{- if and $job.storage (not $spec.storage) -}}
{{- fail (printf "spec.cronJobs.%s: `storage: true` mounts spec.storage, and this app declares none" $name) -}}
{{- end -}}
{{- end -}}
{{- $jobs | toYaml -}}
{{- end -}}

{{/*
The labels every cron job pod carries — and, as importantly, the one it does
NOT: `app`. The Service and the app's NetworkPolicy select on
app.selectorLabels (`app` + `environment`), so a job pod stamped with them
would be admitted as a Service endpoint. It has no readiness probe, so it would
count as ready the moment it started, and Traefik would route live traffic to
a process that is not listening. `app.kubernetes.io/component: cronjob` is what
the jobs' own NetworkPolicy selects instead.
*/}}
{{- define "app.cronJobSelectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/component: cronjob
environment: {{ .Values.environment }}
{{- end -}}
