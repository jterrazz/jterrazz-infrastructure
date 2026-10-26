{{- define "app.name" -}}
{{- .Values.metadata.name | required "metadata.name is required" -}}
{{- end -}}

{{/* invariant: the resolved `spec` of the environment being rendered; maps deep-merge with the
environment winning, lists are replaced (README.md, Merge semantics). */}}
{{- define "app.merged" -}}
{{- $env := .Values.environment -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- mergeOverwrite (deepCopy .Values.spec) (deepCopy $envConfig) | toYaml -}}
{{- end -}}

{{/* hazard: an undeclared environment renders an empty release (ADR-010). */}}
{{- define "app.envExists" -}}
{{- $env := .Values.environment -}}
{{- if and $env (hasKey .Values.environments $env) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "app.ingressList" -}}
{{- $list := (fromYaml (include "app.merged" .)).ingress -}}
{{- if not (kindIs "slice" $list) -}}
{{- fail "ingress must be a list of { host, path?, public } entries" -}}
{{- end -}}
{{- $list | toYaml -}}
{{- end -}}

{{/* invariant: set by app CI as `<registry>/<app>@sha256:...`, or pinned in a platform values file. */}}
{{- define "app.image" -}}
{{- (fromYaml (include "app.merged" .)).image | required "spec.image is required: app CI sets it to the image digest it built" -}}
{{- end -}}

{{/* invariant: `<n>Mi` or `<n>Gi` in MiB, else "", which every caller leaves alone. */}}
{{- define "app.memMi" -}}
{{- $mem := . | toString -}}
{{- if hasSuffix "Mi" $mem -}}
{{- trimSuffix "Mi" $mem | int -}}
{{- else if hasSuffix "Gi" $mem -}}
{{- mul (trimSuffix "Gi" $mem | int) 1024 -}}
{{- end -}}
{{- end -}}

{{/* invariant: memoryLimit, else twice the request in Mi. */}}
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

{{/* invariant: 75% of the request, and nothing below 512Mi, where the cap starved SSR boot. */}}
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

{{- define "app.secretsName" -}}
{{ include "app.name" . }}-secrets
{{- end -}}

{{/* invariant: the one catalog of platform services: the env a consumer gets, the egress it
opens on POD ports, and the clientLabel the target's ingress selects on (README.md). */}}
{{- define "app.platformCatalog" -}}
otel-collector:
  env:
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.platform-telemetry:4318"
  egress:
    namespace: platform-telemetry
    ports:
      - 4317
      - 4318
studio-intelligence:
  env:
    STUDIO_INTELLIGENCE_BASE_URL: "http://studio-intelligence.studio-intelligence-prod.svc.cluster.local/v1"
  egress:
    namespace: studio-intelligence-prod
    ports:
      - 8317
  clientLabel: platform-client.jterrazz.com/studio-intelligence
{{- end -}}

{{/* invariant: the one accessor every consumer calls, so an unknown name always fails. */}}
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

{{/* invariant: exec, then tcp, then httpGet; livenessPath applies to startup and liveness. */}}
{{- define "app.probe" -}}
{{- $spec := fromYaml (include "app.merged" .ctx) -}}
{{- $health := $spec.health -}}
{{- if $health.exec -}}
exec:
  command:
    {{- range $health.exec }}
    - {{ . | quote }}
    {{- end }}
{{- else -}}
httpGet:
  path: {{ ternary $health.livenessPath $health.path (and .liveness (not (empty $health.livenessPath))) }}
  port: {{ $spec.port }}
{{- end -}}
{{- end -}}

{{/* invariant: an image on our registry gets the pull secret; nothing else does. */}}
{{- define "app.privateImage" -}}
{{- if hasPrefix (printf "%s/" .Values.registry.server) (include "app.image" .) -}}
true
{{- end -}}
{{- end -}}

{{/* invariant: a string is content at /app/<filename>; a { path, content } map goes where the
image wants it. */}}
{{- define "app.configFilePath" -}}
{{- if kindIs "map" .file -}}
{{- .file.path | required (printf "spec.configFiles.%s is a map, so it must carry `path:` (and `content:`)" .filename) -}}
{{- else -}}
/app/{{ .filename }}
{{- end -}}
{{- end -}}

{{- define "app.configFileContent" -}}
{{- if kindIs "map" .file -}}
{{- .file.content | required (printf "spec.configFiles.%s is a map, so it must carry `content:` (and `path:`)" .filename) -}}
{{- else -}}
{{- .file -}}
{{- end -}}
{{- end -}}

{{/* invariant: the hardened defaults with spec.securityContext merged over them; anything past
baseline Pod Security fails the render. */}}
{{- define "app.containerSecurityContext" -}}
{{- $spec := fromYaml (include "app.merged" .) -}}
{{- $secDefaults := dict
      "allowPrivilegeEscalation" false
      "capabilities" (dict "drop" (list "ALL"))
      "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- if not $spec.runAsRoot -}}
{{- $_ := set $secDefaults "runAsNonRoot" true -}}
{{- end -}}
{{- $override := $spec.securityContext | default dict -}}
{{- $extraCaps := without (dig "capabilities" "add" (list) $override) "NET_BIND_SERVICE" -}}
{{- if or $override.privileged $override.allowPrivilegeEscalation $extraCaps -}}
{{- fail (printf "spec.securityContext of %s may not set privileged, allowPrivilegeEscalation or add a capability other than NET_BIND_SERVICE: Pod Security refuses them in an app namespace, and this chart refuses them first, at render time" (include "app.name" .)) -}}
{{- end -}}
{{- toYaml (mergeOverwrite (deepCopy $secDefaults) $override) -}}
{{- end -}}

{{- define "app.podSecurityContext" -}}
{{- if not (fromYaml (include "app.merged" .)).runAsRoot -}}
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
{{- end -}}
{{- end -}}

{{/* invariant: shared by the Deployment and every cron job, so a job runs with the app's env. */}}
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
{{- /* invariant: the collector reads `deployment.environment`; Langfuse the semconv `.name`. */}}
{{- if not (hasKey $envVars "OTEL_RESOURCE_ATTRIBUTES") }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "deployment.environment={{ $ctx.Values.environment }},deployment.environment.name={{ $ctx.Values.environment }}"
{{- end }}
{{- range $key, $value := $platformEnv }}
{{- if not (hasKey $envVars $key) }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
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

{{- define "app.alerts" -}}
{{- include "common.alerts" (dict "alerts" (fromYaml (include "app.merged" .)).alerts "field" "spec.alerts") -}}
{{- end -}}

{{/* invariant: the label the ownership policy judges a PV by; a value cannot hold the `/`. */}}
{{- define "app.volumeLabels" -}}
{{ include "app.labels" . }}
{{- with .Values.meta.repository }}
app.jterrazz.com/repository: {{ splitList "/" . | last | quote }}
{{- end }}
{{- end }}
