# ADR-015: Deploy secrets are fetched once by Ansible; workload secrets are synced by the operator

**Status:** Accepted
**Date:** 2026-10-24

Written 2026-10-24 from the comments in `group_vars`, `src/ansible/roles/secrets`,
`roles/platform` and the app chart's registry pull-secret tests (commits
52aa825 and c711e12) that this record replaces.

## Context

Every secret lives in Infisical (project `studio-infrastructure`, environment `prod`). Two
kinds of consumer read them: the deploy itself (the Cloudflare tokens, the
registry account, Grafana's admin password, the Tailscale OAuth pair), and
workloads running in the cluster. A secret checked only where it is used
fails halfway through a deploy; one with a default fails worse, green, with
a known password. Secrets also leak through shells (a `$` or backtick in a
token, a bcrypt hash full of `$`), through argv (`ps`), and through Helm's
release Secrets and `helm get values`.

## Decision

- **The deploy's secrets are one list**, `infisical_secrets` in `group_vars`,
  fetched by `roles/secrets` on the controller (the laptop or the runner)
  before any role runs, failing on a missing key before anything deploys.
  Each folder is fetched explicitly, never recursively, so short key names
  can repeat; `scope: site` entries (the Tailscale pair) are fetched only by
  `site.yml`. The universal-auth identity comes from the environment (`.env`
  or GitHub secrets) and is kept as a fact, because the in-cluster operator
  needs it and it cannot come from Infisical itself.
- **The fetch is an `include_role`**, not a `roles:` entry with `when:`: a
  role's `when` is inherited by every task and evaluated per loop item, so
  the loop stopped after its first secret and the first CI deploy failed
  (fixed in c711e12). `apply: tags: [always]` hands it to targeted runs.
- **Bootstrap Secrets go through the k8s module**, never a shell
  `--from-literal`; htpasswd reads the password on stdin, never as an
  argument. The registry account NAME comes from Infisical too: a rotation
  overlaps two accounts (`deploy` / `deploy-next`), and a hardcoded name
  regenerated a line for an account nobody used, which put the fleet in
  ImagePullBackOff on 2026-09-06.
- **Workloads get their secrets from the Infisical operator**, never from
  Ansible: an `InfisicalSecret` per release, rendered by the charts, synced
  into a Secret whose name is a contract (`secretName` is required; managed
  Secrets are `Orphan`, so deleting a release does not log a service out).
- **The registry pull secret carries no credential in the chart.**
  `registry-credentials` is written by the operator from the `studio-ci` project
  (env `prod`), the same path CI reads its own `docker login` from. Four
  things hold, and only the unit tests check them: the type is
  `kubernetes.io/dockerconfigjson` (an `Opaque` one named in
  `imagePullSecrets` is accepted and then ignored by the kubelet); the name is
  a literal shared by the Deployment and CronJob templates; the template is
  built with `dict | toJson` and passed to the operator verbatim (a
  hand-written JSON string breaks on a `"` in a password), with `auth`
  because containerd prefers it; and only an image from our registry gets
  it. No `includeAllSecrets`, which would copy every other value at that path.

## Consequences

- Nothing is written to disk on the runner, and no secret has a default.
- A missing secret is a failed deploy before anything changed.
- Rotating a deploy secret is an Infisical edit plus a deploy; rotating the
  registry password is the overlap procedure in
  [Operate](../guides/operate.md#rotating-the-registry-password).
