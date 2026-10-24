{{/* hazard: names and hostPath paths address live data, and hostPath.type and
nodeAffinity are immutable. nodeAffinity renders only for a node name: an empty one is a PV
no node matches. Input dict: name, claimName, labels, size, path, nodeName. */}}
{{- define "common.volume" -}}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .name }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  capacity:
    storage: {{ .size }}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: {{ .path }}
    type: DirectoryOrCreate
  {{- if .nodeName }}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - {{ .nodeName }}
  {{- end }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .claimName }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: {{ .size }}
  volumeName: {{ .name }}
{{- end -}}
