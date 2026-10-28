# ADR-009: One helmfile declares every platform release, applied in three passes

**Status:** Accepted
**Date:** 2026-08-30

Written 2026-10-24 from the comments in `src/kubernetes/helmfile.yaml.gotmpl`,
`src/ansible/roles/platform/` and `group_vars` (commit 4b69385, and the Helm 4
move of 2026-09-19) that this record replaces.

Revised 2026-10-25: the passes are selected by `pass: operators | claims`, no
longer `tier:`, which names the namespace label alone. Later that day a
`pass: cluster` went first: the `cluster` release owns the namespaces, and the
bootstrap Secrets need them to exist on a repave.

## Context

Platform releases used to be hand-written `helm upgrade --install` tasks in
Ansible, each with its chart name, version and values path, plus a
`helm repo add` list, a preview script and Renovate rules repeating the same
facts. A release could be declared in one place and pinned in another, and
nothing rendered the whole set before a deploy touched the cluster.

## Decision

`src/kubernetes/helmfile.yaml.gotmpl` is the only declaration of every platform
release (name, namespace, chart, pinned version, values file) and of the
chart repositories. Ansible holds no chart fact; it applies the file on the
node, and `make diff` reads it from the Mac.

- **It lives in `src/kubernetes/`**, because the node only ever receives that
  subtree (staged to `/tmp/k8s-manifests`) and every path in it is relative.
- **The `.gotmpl` suffix is load-bearing**: helmfile 1.x renders the state
  file as a Go template only when the extension says so, and two values come
  from the environment at parse time through `requiredEnv`: `NODE_NAME`, the
  hostPath PV's nodeAffinity target (Ansible passes the inventory host, the
  Makefile the VM name, so the file names no machine), and
  `GRAFANA_ADMIN_PASSWORD`, set as an inline values map, never `--set`, which
  would put it in argv for `ps` to read. `inherit:` replaces YAML anchors,
  which helmfile 1.x dropped.
- **Passes in dependency order**, selected by a `pass:` label.
  `pass: cluster` first (the namespaces, baselines, RBAC and admission), then
  `pass: operators`
  (cert-manager and the Infisical operator, whose CRDs later passes apply),
  after the three Secrets Infisical cannot provide and before the
  ClusterIssuers; `pass: claims` second (the `<name>-platform` releases:
  PVs, PVCs, Certificates, IngressRoutes and InfisicalSecrets that workloads
  mount and read by name);
  then an unselected pass, so a release with no `pass:` label is still applied.
  Redeploying one release is `helmfile apply -l name=<release>`, not an
  Ansible tag.
- **Namespaces are never created by helm**: `charts/cluster/values.yaml`
  declares them with their Pod Security labels, and helm's
  `--create-namespace` would win the race with an unlabelled one.
- **A pass is done only when no release is failed.** helm-diff compares with
  the LAST revision, failed or not, so a retry of a failed release sees no
  difference, skips it and exits 0 while the old objects run (2026-10-24:
  grafana stuck on revision 23 behind an immutable roleRef, two deploys
  green). Each pass asserts `helm list -A --failed` is empty; the fix is the
  recorded error, then `helmfile sync -l name=<release>`, which does not diff.
  `--detailed-exitcode` maps "changed and synced" to Ansible's `changed`, and
  the diff stays in the log with secrets redacted.
- **The tools are pinned once, in `group_vars`, and checked by version**:
  helm, helm-diff (not optional: `helmfile apply` is diff-then-sync) and
  helmfile. CI installs the same versions from the same file. The get-helm
  script is fetched at a tag, since it runs as root.
- **Helm 4 since 2026-09-19.** Checked before moving: helm-diff 3.15.10+ and
  helmfile 1.4+ speak its flags, helm-unittest embeds its own renderer (the
  snapshots did not move), server-side apply is the default only for releases
  installed under it, and the legacy plugin ABI still loads. The one visible
  difference, plugin signature verification (helm-diff and helm-unittest
  publish none), is answered with `--verify=false` wherever a plugin is
  installed; Helm is pinned to 4.x everywhere.

## Consequences

- Adding a platform service is one release block, one values file, a
  namespace and a NetworkPolicy ([Operate](../guides/operate.md#add-a-platform-service)).
- The release name and namespace are the identity of live data: renaming
  either creates a new release and orphans the hostPath PV the old one bound,
  which is why the `-platform` suffix is frozen.
- CI renders the whole file on every change, so a bad version or a dangling
  `needs:` fails before a deploy rather than halfway through one.
- `deploy.yaml` runs the same play, so it never assumes the host
  layer ran in the same invocation.
