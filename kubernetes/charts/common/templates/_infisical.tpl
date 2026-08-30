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
secretNamespace.
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
      secretType: Opaque
{{- end -}}
