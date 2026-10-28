# ADR-030: An image runs the app, and the chart runs its startup task

**Status:** Proposed
**Date:** 2026-10-29

## Context

The apps with a database migrated it from their image's start command:
signews-api ran `npm start`, whose script chained `prisma migrate deploy`
before `node`, and studio-console a `sh -c` that created the database
directory, migrated and `exec`ed Bun. Both need a shell and a package manager
in the runtime image, which is where most of the fleet's HIGH findings came
from (the npm Alpine and Node images embed), and a failed migration surfaced
as a crash-looping app rather than as a migration that failed. A distroless
runtime, which has no shell, cannot run either form.

## Decision

1. **`spec.migrate` is the startup task**, an argv the app chart runs as the
   pod's one init container, `migrate`: the app's image, env, secrets,
   volumes, securityContext and resources, the argv as the container's
   `command`, so no shell is involved. Empty (the default) renders nothing; an
   environment's list replaces the base one. App chart 7.1.0.
2. **An image starts the app and nothing else**: three stages, a distroless
   runtime, `USER 1000:1000`, an exec-form `ENTRYPOINT`, an allowlist
   `.dockerignore`, no `HEALTHCHECK`
   ([the Dockerfile standard](../reference/dockerfile.md)).

## Consequences

- A failed migration holds the new pod in `Init`. A rolling update never cuts
  over; a Recreate one (every app with storage) has already stopped the old
  pod, so the app is down until the deploy's `--rollback-on-failure` restores
  the previous release, after the deploy's timeout. A pre-upgrade hook Job
  would keep it serving, at the cost of a second writer beside the old pod
  and a hook that runs before a first install has its secrets.
- The migration runs on every pod start, so it must be idempotent, which
  `prisma migrate deploy` is.
- An image whose runtime lacks a library a prebuilt engine links copies it
  from a build stage of the same Debian release; Prisma 6's engines are the
  one case today.
