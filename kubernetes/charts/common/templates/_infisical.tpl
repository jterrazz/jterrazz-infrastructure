{{/*
One InfisicalSecret. Everything that is a property of THIS Infisical project
rather than of a workload — the API host, the project slug, the shared
machine-identity credentials in platform-secrets — is pinned here, so a new
consumer supplies only its own path and destination.

LIST form (`managedKubeSecretReferences`), not the deprecated singular
`managedSecretReference:` map. Same fields, same behaviour for one entry — and
`creationPolicy` is left at its default `Orphan`, which is what the singular
field always did: the managed Secret outlives the CR rather than being
garbage-collected with it.

Input dict: name, labels (rendered lines), envSlug, secretsPath, secretName,
secretNamespace, and two optional ones:

  secretType  the Kubernetes Secret type, `Opaque` unless given. The operator
              copies it straight into the managed Secret's `type:`, which is
              the only way a synced Secret can be the dockerconfigjson an
              imagePullSecret accepts.
  template    the operator's own transform, `{ data: { key: <template> } }`.
              Those templates are rendered by the OPERATOR (text/template with
              sprig in scope), never by Helm, and they REPLACE the default
              key-per-secret projection — `includeAllSecrets` would put the raw
              values back beside them, so a caller that names a template wants
              only what it named.
*/}}
{{- define "common.infisicalSecret" -}}
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  hostAPI: https://eu.infisical.com
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: jterrazz
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
