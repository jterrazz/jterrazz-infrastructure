# ADR-020: Validation gates fail loudly and pin what they run

**Status:** Accepted
**Date:** 2026-10-24

Written 2026-10-24 from the comments in `.github/workflows/validate.yaml`,
`deploy-platform.yaml` and the `Makefile` that this record replaces.

## Context

A push to main can deploy (`deploy-platform.yaml`), so whatever reaches main
unvalidated reaches the cluster. The checks themselves run on hosted runners
whose images drift, against third-party schema catalogs that lag, with tools
downloaded at run time. A gate that skips what it cannot check, or that runs
on whatever the image happens to ship, turns green without having proved
anything.

## Decision

`validate.yaml` runs on pull requests AND on every push to main (a direct
push or an admin bypass would otherwise deploy unvalidated), cancels a stale
run of the same ref (it is read-only; the deploy workflows never cancel), and
follows four rules.

- **Fail on the unknown.** kubeconform tries vendored schemas first
  (`kubernetes/schemas/`, overrides for CRDs whose catalog copy lags the
  version run: today the InfisicalSecret, whose catalog copy marked the
  deprecated `resyncInterval` required and rejected `syncConfig`), then the
  core kinds, then the datreeio catalog, and never
  `-ignore-missing-schemas`: a new CRD kind with no schema fails until the
  list is updated. helm-unittest runs with `--strict`, so a typo'd assertion
  is an error rather than one that never runs. ansible-lint gets `-c`,
  because its config discovery walks up from the working directory and would
  otherwise ignore `ansible/.ansible-lint` without a word.
- **Pin every tool, by digest where one exists.** kubeconform and gitleaks
  are downloaded at a version with a sha256 check, so a re-tagged release
  cannot run. helm-unittest is pinned by tag (a plugin installs from a git
  ref and has no digest) and embeds its own renderer, which is what keeps the
  committed snapshots reproducible between a laptop and CI.
- **Pin the runtimes.** Python is 3.13:
  ansible-core 2.21 needs 3.12 to 3.14 (below 3.12 pip silently resolves an
  ancient core), and 3.13 has the widest wheel coverage for ansible-lint's
  compiled dependencies (cffi, cryptography, ruamel-yaml-clib, which
  ansible-lint drops on 3.14). Node is pinned to a major because the image's
  baked-in npm crashed inside `npm exec` the first time the docs job ran.
- **Pin the content check and the collections.** The content check runs at a pinned `@jterrazz/typescript`, through
  `--package` plus the bin name (the short form makes npm infer `typescript`,
  which collides with one of the package's own dependencies and died on the
  runner with `edgesOut`), because an unpinned release would turn a green
  tree red the day it added rules. Ansible collections are exact pins
  (a `>=` floor lets a clean runner and a warm laptop resolve different
  versions) installed from their GitHub tags, not Galaxy, which answered
  HTTP 500 on every download for hours on 2026-10-24 and took Validate and
  Deploy Platform down with it; a git source resolves no dependencies, so
  community.general's one dependency is pinned by hand.
- **Read versions where the applier reads them.** helm and helmfile come from
  `group_vars`, helm-unittest from `make print-helm-unittest-version`, so the
  renderer in CI is the applier on the node. Rendering the whole helmfile
  catches a bad chart version, a moved values file or a dangling `needs:`
  before a deploy, not after some releases were upgraded.
- **Exercise the real templates.** Default values render almost nothing, so
  each chart is linted and rendered against its `ci/test-values.yaml`;
  kubeconform proves schema validity only, and helm-unittest asserts what the
  templates computed (a heap cap, an escaped dockerconfigjson, the
  ipAllowList an `access:` value selects). Raw manifests among the values
  files are found by a top-level `apiVersion:`, never by a list.

Secrets scanning is the one deliberate scope limit: gitleaks runs with
`--no-git` on the checked-out tree. The history predates any secret hygiene
and holds credentials since rotated; scanning it would fail forever, and the
remedies (a filter-repo rewrite, a baseline of historical findings) were
ruled out. The gate stops NEW secrets, with `--redact` so a true positive
does not leak again into a public log. There is no `.gitleaks.toml`: a
fixture that tripped a rule was rewritten to an obviously non-secret form
(the registry credentials in the app chart's fixture, decode-and-match
assertions in its tests), which keeps every scanner quiet, GitHub's
included. An allowlist is the last resort, and none exists.

## Consequences

- A laptop's `make check` can soft-skip actionlint, helm-unittest and the
  content check, because CI runs all three unconditionally.
- A new CRD kind, a lagging catalog schema or a tool bump is a red build
  first and a reviewed change second.
- Credentials already in history stay there; rotation, not scanning, is what
  neutralised them.
