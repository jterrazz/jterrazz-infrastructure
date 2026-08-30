{{/*
DATA-DESTROYING IF CHANGED. Object names and hostPath paths address LIVE data;
both charts' callers derive them and this template invents none.

  PV   `name`      — the PVC binds to it by volumeName, so the two can never
                     drift apart here.
  PVC  `claimName` — usually the same string. It differs when the consumer
                     imposes a name: a StatefulSet volumeClaimTemplate looks
                     for storage-<release>-<ordinal> and silently provisions a
                     FRESH dynamic volume if it does not find one, which is how
                     Loki and Tempo lost every log and trace.
  path `path`      — an absolute hostPath. Moving it moves the directory and
                     the pod comes up on an empty volume.

hostPath.type is an IMMUTABLE PV field, so the unconditional DirectoryOrCreate
below only applies to freshly created PVs.

nodeAffinity pins the PV to the node holding the data, and is emitted ONLY when
a node name is supplied: an empty one renders `values: [""]`, a PV that matches
no node and can never bind. It is immutable once set, so adding it to a
pre-existing PV means delete-and-recreate the PV object (the DATA survives —
hostPath dirs plus a Retain reclaim policy).

Input dict: name, claimName, labels (rendered lines), size, path, nodeName.
Emits the leading `---` for both objects, so a caller can call it in a loop.
*/}}
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
