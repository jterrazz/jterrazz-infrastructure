# ADR-016: Every fact has one home, and the cluster is discovered, not listed

**Status:** Accepted
**Date:** 2026-10-24

Revised 2026-10-27: the smoke annotations are `studio.jterrazz.com/smoke-*` and the
repository stamp `studio.jterrazz.com/repository` ([ADR-029](029-an-app-is-declared-strictly-reads-its-own-secrets-and-is-reached-by-consent.md)).

Written 2026-10-24 from the comments in the charts, `group_vars`,
`validate.yaml` and the `Makefile` that this record replaces (discovery
landed on 2026-08-30 in c64340d and 74a0144; `assert-sync.py` was deleted
on 2026-10-24 in 52aa825, -1,150 lines).

## Context

Facts written down twice drift. This tree used to hold many such pairs (a
tool version in Ansible and in CI, a hostname list in DNS and in CoreDNS, a
release's chart version in Ansible and in a preview script, a smoke table
of hostnames and status codes, a list of app repositories to redeploy), held
together by `assert-sync.py`, a checker that grew as fast as the pairs did.
A checker for a pair is a second fact about the first two.

## Decision

Give every fact one home and make every other reader read it there, or
derive it from the cluster.

- **Versions are read where the applier reads them.** helm and helmfile from
  `group_vars` (CI's `yq`), helm-unittest from
  `make print-helm-unittest-version`, the k3s image of the upgrade test from
  `k3s_version`, the node's MagicDNS name from the CI inventory.
- **Smoke reads its checks off the routes.** Each IngressRoute carries
  `smoke.jterrazz.com/{path,expect,method,location,probe}` annotations, which
  the charts stamp from facts the service already declares (the contract is
  `common/templates/_smoke.tpl`). The annotations ARE the check: a wrong one
  is a probe that passes while the service is down, and a missing one falls
  back to the weakest claim (`GET / -> 200`), named in the output.
- **The defaults are derived.** The app
  chart's probes are right with no edit: a stripped `/api`
  becomes `/api/health`, and a redirect's expected `Location` comes from the
  same replacement its Middleware is built from, so the two cannot disagree;
  an app that routes its own prefix opts out rather than be probed at a
  guessed URL. A platform service overrides only where an unauthenticated
  caller gets something else (a login redirect, a 401), never accepting 000
  or a 5xx; annotation values are strings, and an unquoted 401 fails the
  apply.
- **Redeploy reads the repositories off the Deployments.** App CI passes
  `meta.repository`, stamped as `app.jterrazz.com/repository`; an app whose
  CI predates it is reported missing, never guessed.
- **What remains doubled is a named list**, each with its checker or an
  admission that it has none: [Hand-synced pairs](../reference/hand-synced-pairs.md).

## Consequences

- A surface an app added yesterday is probed today with no edit here.
- A repave leaves nothing to discover, so the fleet is snapshotted before
  (`--dry-run > file`) and replayed after (`--from file`).
- A new pair is a design smell to remove, not a row to add to a checker.
