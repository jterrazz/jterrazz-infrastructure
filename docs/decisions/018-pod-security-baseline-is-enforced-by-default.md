# ADR-018: Pod Security baseline is enforced everywhere by default

**Status:** Proposed
**Date:** 2026-10-24

Written 2026-10-24 from the comments in `kubernetes/cluster/namespaces.yaml`,
the app chart's hardening tests and the k3s Pod Security template (commit
4584007) that this record summarises; the template keeps its comments, since
it is rendered onto the node.

## Context

Platform namespaces labelled themselves with Pod Security levels in
`cluster/namespaces.yaml`. App namespaces are created by each app's CI and
label nothing, so before this decision they ran with no admission check at
all (audit 2026-10-24).

## Decision

- **A cluster default** (`pod-security.yaml.j2`, wired with
  `admission-control-config-file`): enforce `baseline`, audit and warn
  `restricted`, for every namespace without labels of its own. Every app pod
  passed baseline in a server-side dry run on 2026-10-24. Restricted is only
  audited, because the app chart's fix-permissions init container runs as
  root with CHOWN, FOWNER and DAC_OVERRIDE. kube-system is exempt: k3s' svclb
  and helm-install pods need NET_ADMIN.
- **Platform namespaces are declared in one file** with the same levels;
  `platform-networking` and `platform-telemetry` enforce `privileged`,
  because cloudflared and node-exporter need hostNetwork and hostPath, which
  baseline forbids. Never `kubectl create ns`, and never helm's
  `--create-namespace`, which would create an unlabelled namespace first and
  win the race; an app namespace that needs labels before its first deploy
  (`prod-gateway-intelligence`) is pre-declared there, and Helm adopts it.
- **An app cannot opt out**: the ownership policy refuses a `privileged`
  level on a namespace an app creates.
- **The app chart fails at render** when an app loosens its securityContext
  past what baseline admits, so the app's own CI log says why, instead of an
  admission error inside a `helm --atomic` rollback.

## Consequences

- Every app pod is admission-checked, and restricted violations are visible
  in audit before anyone enforces them.
- Enforcing restricted would first need the chown init container gone.
- The upgrade test catches a Pod Security refusal before the real cluster.
