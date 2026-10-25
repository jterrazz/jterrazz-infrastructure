# ADR-008: Storage on OrbStack spends fsyncs, not bytes

**Status:** Accepted
**Date:** 2026-08-23

Written 2026-10-24 from the comments in `roles/base`,
`src/kubernetes/cluster/storage-class.yaml` and the Victoria, OpenPanel, Grafana
and collector values (commits 3a94b34, 61be749, 00c90a2) that this record
replaces.

Revised 2026-10-25: ownership on the share is not enforced; the chown init containers went.

## Context

OrbStack honours a guest `fsync()` with a real durable barrier on the Mac: a
macOS `F_FULLFSYNC`, an APFS journal commit. macOS' own `fsync()` only
reaches the drive cache. So the cost is per fsync, not per byte (sequential
writes run 1:1), measured at about 135KB of SSD writes per fsync over
virtiofs and about 330KB per FLUSH on the VM disk (300 fsyncs wrote 99MB).
A store writing 15MB a day can cost tens of GB a day if it fsyncs on a 5s
timer. Upstream tracks the symptom in orbstack/orbstack#1332, open and
undiagnosed; there is no OrbStack setting for it.

There are two paths, with different levers:

- **virtiofs**: `/var/lib/k8s-data`, a symlink into the Mac home, so every
  PV. The fsync is a FUSE request the guest cannot suppress.
- **The VM disk**: `/dev/vdb`, btrfs, holding kine's SQLite, containerd and
  `/var/log/pods`. The fsync is a virtio-blk FLUSH.

## Decision

Keep live data on the Mac, so it survives a repave, and cut the number of
fsyncs on each path with the lever that path has.

- **Every persistent volume is static.** The `manual` StorageClass
  (no-provisioner, WaitForFirstConsumer, `Retain`) binds pre-declared hostPath
  PVs under `/var/lib/k8s-data`, one directory per app, nested for a
  multi-component app; both charts emit the PV and PVC pairs. Deleting a PVC
  keeps the data.
- **The VM disk is write-through.** `virtio-blk-write-through.service` sets
  `queue/write_cache=write through` on `/dev/vd*` at every boot (the
  attribute is runtime-only), before k3s, so the block layer stops sending
  FLUSHes (300 fsyncs: from 99MB to 0MB). The data still lands in the Mac's
  page cache, so only a macOS panic or power loss can lose the last seconds,
  the contract every native Mac app gets. OrbStack runs one Linux VM for all
  machines and Docker, so the setting is OrbStack-wide; it does nothing for
  virtiofs (verified).
- **On virtiofs, the workload is the lever.**
  `-inmemoryDataFlushInterval` is 60s on VictoriaMetrics and VictoriaLogs
  (default 5s; each flush writes a new part directory, and a graceful stop
  still flushes, so only an unclean exit loses up to a minute) and 300s on
  VictoriaTraces, whose flush writes a 32 to 74 file part holding a few KB
  and whose history is already accepted as losable. OpenPanel's Redis runs
  `--appendfsync no` (the default `everysec` is one fsync per second forever,
  for a job queue that churns keys; a pod restart still replays the AOF).
- **Data worth nothing after a repave stays off virtiofs.** The collector's
  filelog offsets (a bbolt file) sit on a node-local hostPath. Grafana's
  volume uses `nodeLocalPath`, in the VM, because Grafana works it
  continuously; a repave resets logins, annotations and dashboard history,
  and everything that matters is provisioned from git. It is the one PV that
  does not survive `make destroy`.

- **Ownership is not enforced on the share.** virtiofs here presents every file
  as owned by the reader and ignores `chown`: a uid-1000 process writes into a
  root-owned, mode-700 directory (verified 2026-10-25). So no workload carries
  a chown init container, which had walked 145k files of the Victoria stores
  on every start for nothing.

## Consequences

- `make destroy` keeps every PV but Grafana's.
- Moving `k8s-data` onto the VM disk would make its fsyncs free too, at the
  cost of losing data with the VM; that trade stays open, a decision rather
  than a tuning.
- Every new store on virtiofs owes a look at how often it fsyncs.
- `findmnt` on the symlink prints nothing; `readlink -f` first.
