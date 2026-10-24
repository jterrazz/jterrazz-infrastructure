# ADR-022: The platform contract is a TypeScript suite on @jterrazz/test, run from two vantages

**Status:** Accepted
**Date:** 2026-10-24

## Context

What the deployed platform promises was checked by `src/scripts/smoke.sh`, 419
lines of bash around an embedded Python program, plus
`src/scripts/trigger-app-deploys.sh` for the fleet. The script probed what every
IngressRoute's `smoke.jterrazz.com/*` annotations say and the certificates'
expiry, from one runner joined to the tailnet. It held no negative probe: an
audit on 2026-10-24 found the class of hole it could not see (a private host
reachable from outside, a NodePort open, a cluster-wide Secret read granted
to an identity that should not have it), because a machine on the tailnet
reaches everything, and nothing asked what the internet must NOT reach. It
also listed the IngressRoutes by SSH as root, with the deploy key, to read
four annotations.

Every other repository of the estate writes its tests on `@jterrazz/test`,
whose 18.3 meets an already deployed api at its `url`
(`specification.api({ url })`: one exchange compared whole, a redirect never
followed, `unreachable: <reason>` as a result rather than an exception, the
certificate as a fact of the result).

## Decision

The platform contract is a suite under `specs/`, on `@jterrazz/test`,
read from the live objects and never from a list, and run from the vantage
each claim needs.

- **Routes, certificates and the boundary are HTTP specs** (`specs/specs/api/`):
  each discovered route answers its annotated contract, each host presents
  a trusted certificate that covers it with 15 days or more left, and from
  the internet every private host never answers while every public host
  refuses a request that names a private one.
- **What the API server holds is a repository suite** (`specs/specs/cluster/`,
  `specs/specs/routes/`): Secret reads by service account against an allow-list,
  the github-actions group's reach, Traefik's Service, namespace ownership,
  and `private_hostnames` against the tailnet-only routes, both ways.
- **The ownership policy is proven on k3d** (`specs/specs/admission/`): its cases
  impersonate app identities, which needs an admin credential, so they run
  in the upgrade test and never against the live cluster.
- **The node is proven over the deploy's SSH connection** (`specs/specs/host/`):
  sshd's effective config, the nft guard, unattended-upgrades, k3s' secret
  encryption and the Pod Security default, after every platform deploy.
- **Two vantages.** `smoke.yaml` runs a tailnet job (routes, certificates,
  cluster, inventory) and an internet job that never joins the tailnet
  (public routes and the boundary negatives), which probes the IngressRoute
  snapshot the tailnet job took, since the internet cannot reach the
  apiserver.
- **CI reads the cluster as itself.** The tailnet job builds an OIDC
  kubeconfig as `docker-deploy` does and reads as user
  `github:jterrazz/jterrazz-infrastructure`, bound to the read-only
  `platform-reader` ClusterRole (`src/kubernetes/cluster/platform-reader.yaml`);
  the smoke workflow holds no SSH key any more.
- **The harness is a project of its own.** `specs/` is a private `cli` on
  node, the kind `@jterrazz/typescript` gives a TypeScript harness of a
  product written in another language; it also holds `make redeploy-apps`.
  The root stays `content`: a root `package.json` would make the whole
  repository a code project, whose formatter rewrites every values file and
  page, and the toolchain has no door for a content repository with a suite.

## Consequences

- A hole of the audited class fails a scheduled run instead of waiting for
  the next audit, and each probe that fails says which host and why
  (`unreachable: dns`, a status outside the contract, a margin in days).
- Two runs of `npm ci` and a Node toolchain join the workflows; the
  harness's lockfile pins it, and Renovate's npm manager watches it.
- The live Pod Security default is proven on the node with its admin
  `kubectl`, not by `platform-reader`, which may not create pods even in a
  dry run.
- `specs/` sits outside the content gate's reach and is judged by its own
  `typescript check` (`make harness-check`, `validate.yaml`); a content root
  that could hold a suite member would fold the two gates back into one.
