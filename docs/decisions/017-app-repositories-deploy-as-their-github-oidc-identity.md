# ADR-017: App repositories deploy as their GitHub OIDC identity and own what they create

**Status:** Accepted
**Date:** 2026-10-24

Written 2026-10-24 from the comments in `kubernetes/cluster/app-deployers/`,
`group_vars` and the k3s authentication template (commits 4584007 and
f244821) that this record summarises; the authentication template keeps its
comments, since it is rendered onto the node.

## Context

Each app repository deploys itself from its own CI: it creates its
namespaces, its PersistentVolume, and runs `helm upgrade` there. That used
to need a stored cluster credential shared by every repository, which made
any one repository's CI a cluster admin over all the others.

## Decision

The apiserver trusts GitHub Actions' OIDC issuer directly, and what an
identity may do is RBAC plus one ValidatingAdmissionPolicy.

- **Identity.** A workflow of `jterrazz/<repo>` on `main` or a `v*` tag
  (release-docker deploys the `next` environments from one), asking for
  audience `k3s_oidc_audience`, authenticates as user `github:jterrazz/<repo>`
  in group `github-actions:jterrazz`. The token is minted per job and expires
  with it; nothing is stored. The claim rules are the whole trust boundary:
  without the `repository_owner` rule any public repository could mint an
  accepted token, without the ref rule any branch could deploy. The audience
  is hand-synced with `jterrazz-actions/actions/docker-deploy`.
- **RBAC.** Cluster-wide, the group gets `app-deployer` (namespaces
  get/create/update/patch, PersistentVolumes, RoleBindings, and `bind` on
  `app-namespace-admin` only). Inside a namespace, the repository binds
  `app-namespace-admin` to itself (the app chart's kinds, Helm's release
  Secrets, the reads `--wait` needs; no exec, no RBAC, no Pod Security
  labels). Nothing grants a read across namespaces: admission sees writes,
  never reads, so a cluster-wide `list secrets` would leak every Secret
  whatever the policy says.
- **Ownership, by policy.** There is no list of apps: a repository creates
  its namespaces on its first deploy and owns them through the
  `app.jterrazz.com/repository` label (the bare name, since a label value
  cannot hold a `/`). For any write by a `github:` identity: a namespaced
  object's namespace must carry its label; a Namespace or PersistentVolume
  must carry it on create, keep it on update and delete, and cannot move it;
  a Namespace may not opt out of Pod Security; a PersistentVolume is a
  hostPath at `/var/lib/k8s-data/<name minus -data>`, never the node's root
  or another app's directory; a RoleBinding binds `app-namespace-admin` to the
  requester and nobody else. The existing namespaces and volumes were
  labelled once by hand on 2026-10-24, from each Deployment's repository
  annotation.

## Consequences

- No credential to rotate or leak; a repository's reach ends at the
  namespaces it created.
- Residual risk, written down rather than hidden: nothing owns a HOST. A
  repository can declare an IngressRoute or Certificate for any name in our
  zones from its own namespace; closing that needs a cross-object lookup,
  which CEL admission cannot do.
- How an app deploy authenticates, from the app's side, is
  [the deploy contract](../reference/deploy-contract.md#how-a-deploy-authenticates).
