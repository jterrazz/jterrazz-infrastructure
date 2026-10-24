# ADR-007: k3s runs single-node on SQLite, upgraded in place one minor at a time

**Status:** Accepted
**Date:** 2026-07-26

Written 2026-10-24 from the comments in `src/ansible/roles/k3s/` and
`group_vars` (the single-target restructure, dfc3c78, and 1d3e207, which
disabled local-path) that this record summarises. The k3s templates keep
their own comments: they are rendered onto the node, and editing them
restarts k3s.

## Context

One node, reproducible from `deploy.sh` plus Ansible, with every byte of app
data on hostPath volumes. A Kubernetes distribution defaults to choices made
for clusters: replicated etcd, a dynamic provisioner as the default
StorageClass, an uncapped audit surface. On a memory-bound VM each of those
costs something and buys nothing, and some are traps.

## Decision

- **Kine on SQLite, no `cluster-init`.** Embedded etcd holds its keyspace in
  RAM and runs its own compaction and snapshots, about 150 to 300Mi more RSS
  for zero benefit on one node. Re-add it only for multi-node HA.
- **`local-storage` disabled.** Every PVC uses the `manual` class against a
  pre-declared hostPath PV, so the provisioner has nothing to do; and it
  ships as the DEFAULT class with `reclaimPolicy: Delete`, so a PVC that
  forgot `storageClassName` would land on ephemeral storage and be deleted
  with its claim. With no default class, such a PVC stays Pending: loud and
  harmless.
- **kubelet's `resolv-conf` is pinned** to
  `/run/systemd/resolve/resolv.conf`, the uplink file. With the 127.0.0.53
  stub, CoreDNS (`dnsPolicy: Default`) forwards into itself and its loop
  plugin fatals at startup.
- **TLS SANs are the tailnet IP and MagicDNS name**, the addresses the laptop
  and CI use; `ansible_host` (`orb`) is never one, no client can present it.
- **Flags k3s silently ignores are a trap**: Pod Security is wired with the
  plain apiserver flag `admission-control-config-file`;
  `pod-security-admission-config-file` is RKE2's key, accepted by k3s and
  ignored.
- **`k3s_version` lives in `group_vars` only**, deliberately absent from role
  defaults (a role default wins only when group_vars is not loaded, so two
  copies drift silently). The supported upgrade is in place: the role re-runs
  get.k3s.io with `INSTALL_K3S_VERSION` and restarts the unit, which takes the
  control plane down for tens of seconds while containers keep running.
  Never skip a minor (the version-skew policy forbids it), and re-read the
  bundled Traefik values in the same change
  ([the Traefik record](003-traefiks-service-is-the-tailnet-gate.md)).

## Consequences

- No HA and no etcd snapshots: recovery is a repave plus a data restore,
  which the hostPath layout makes possible.
- A comment edit in a k3s template is a k3s restart on the next `make
  deploy`, which is why those comments stay where they are.
- Security-related server flags (secrets encryption, audit log, OIDC,
  Pod Security) are their own records.
