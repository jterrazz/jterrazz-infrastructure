{{/* Input dict: name, labels, envSlug, secretsPath, secretName, secretNamespace; optional
projectSlug (default jterrazz), secretType (default Opaque) and template, the operator's own
transform, which replaces the key-per-secret copy. The managed Secret is Orphan: it outlives
the CR. */}}
{{- define "common.infisicalSecret" -}}
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  hostAPI: https://eu.infisical.com
  # value: the operator's own default, spelled out: unset, it logs a deprecation banner on
  # every reconcile, 40% of its lines.
  syncConfig:
    resyncInterval: 5m
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: {{ .projectSlug | default "jterrazz" }}
        envSlug: {{ .envSlug }}
        secretsPath: {{ .secretsPath }}
      credentialsRef:
        secretName: infisical-credentials
        secretNamespace: platform-secrets
  managedKubeSecretReferences:
    - secretName: {{ .secretName }}
      secretNamespace: {{ .secretNamespace }}
      secretType: {{ .secretType | default "Opaque" }}
      {{- with .template }}
      template:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
