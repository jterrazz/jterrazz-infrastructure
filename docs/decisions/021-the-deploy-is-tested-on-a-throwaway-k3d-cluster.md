# ADR-021: The deploy is tested by running it on a throwaway k3d cluster

**Status:** Accepted
**Date:** 2026-10-24

Written 2026-10-24 from the comments in `.github/workflows/upgrade-test.yaml`
(commits c0d1f87 and eabdd15) that this record replaces.

## Context

Every tree-side check reads the deploy code; none runs it. On 2026-10-24 a
change to Grafana's ClusterRoleBinding `roleRef`, an immutable field, passed
every check and left the `grafana` release failed on the real cluster. The
same class covers admission refusals (Pod Security, the app-deployer
ownership policy), schemas the live API server rejects, and tasks that break
on a re-run: all invisible until an apply.

## Decision

`upgrade-test.yaml` creates a k3d cluster at the production k3s version (read
from `group_vars`), deploys it with the real `platform.yml` from the BASE tree
(the pull request's base, the commit before a push, or a dispatched `base`;
`HEAD` gives a re-run test), then upgrades it with the same play from this
tree. Each pass ends on the play's own `helm list --failed` assertion.

- **No copy of the deploy code.** `src/ansible/inventories/k3d.yml` points the
  play at the throwaway cluster; it is copied from this tree into the base
  checkout, which may predate it, while group_vars still resolve from each
  tree's own inventory.
- **Nothing leaves the runner.** Secrets are dummy extra vars (roles/secrets
  is skipped when they are defined); the `dns-records` and `chart-publish`
  tags are skipped, since they reach the real Cloudflare zone and the real
  registry.
- **It proves releases apply, not that pods start.** With no real secrets
  most workloads wait on a Secret that never comes, so
  `platform_helm_wait: false` keeps helm from waiting (cert-manager and the
  Infisical operator wait regardless, since later passes need their
  webhooks). Starting is the smoke probe's job, on the real cluster.
- The play's k8s modules run on the runner here rather than on the node, so
  the runner installs `kubernetes==30.1.0`, the version Debian ships to the
  node as `python3-kubernetes`.

## Consequences

- An upgrade-only failure surfaces on the pull request, before
  `deploy-platform.yaml` runs.
- About one k3d cluster's worth of runner time per change to `src/ansible/` or
  `src/kubernetes/`.
- What it cannot see (a pod that crash-loops, a route that no longer
  answers) stays with smoke; see [Test](../guides/test.md#the-upgrade-test-runs-the-deploy-itself).
