# The Dockerfile standard

What an app's image owes the cluster. The app chart runs every image the same
way: as uid 1000, with its probes, its volumes and its startup task declared in
`.infrastructure/application.yaml`
([app chart README](../../src/kubernetes/charts/app/README.md)). An image that
follows the rules below needs nothing else from the chart.

## The rules

| Rule                                                                                     | Why                                                                                                                                                                                                               |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Three stages**: production dependencies, build, runtime                                | The runtime copies the production `node_modules` and the build output, nothing else: no compiler, no lint toolchain, no dev dependency reaches the image, so the scanner has nothing of theirs to report.         |
| **A distroless runtime**: `oven/bun:<minor>-distroless`, `gcr.io/distroless/nodejs<major>-debian13:nonroot`, `gcr.io/distroless/base-nossl-debian13:nonroot` for a binary | No shell and no package manager to exploit or to carry CVEs, and glibc, which prebuilt native addons expect (musl breaks them). Build stages use the same Debian release, so a native addon built there loads here. |
| **`USER 1000:1000`**, numeric                                                            | The uid the chart runs pods as (`runAsUser`, `fsGroup`). Numeric, so `runAsNonRoot` can verify it, and the same uid locally as in the cluster.                                                                   |
| **`ENTRYPOINT` in exec form**, the runtime's absolute path, no `sh -c`, no `npm start`   | The app is PID 1 and receives SIGTERM itself; a wrapper swallows it and the pod dies at the end of its grace period. PID 1 has no default signal action, so the app installs a SIGTERM handler.                    |
| **No startup task in the image**: a migration is the chart's `migrate:`                  | `migrate:` runs it as an init container of the same image, env, secrets and volumes, without a shell. A failed migration holds the new pod back instead of crash-looping the app.                                 |
| **An allowlist `.dockerignore`**: `*`, then `!` each input                               | The context is what the build reads and nothing more: no `.env`, `.git`, local `node_modules` or credentials can be copied by a `COPY . .`.                                                                        |
| **No `HEALTHCHECK`**                                                                     | Kubernetes ignores it; the probes are the chart's `health:`, and a check would need a shell or `wget` the image no longer has.                                                                                     |

The OCI labels, the SBOM and the provenance are the build action's
(`studio-actions`), not the Dockerfile's.

## The template

A Bun app on a single `package.json`; a workspace member copies the workspace
manifests and installs with `--filter <member>`, as studio-os's console
does.

```dockerfile
# syntax=docker/dockerfile:1
FROM oven/bun:1.4 AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production --ignore-scripts

FROM oven/bun:1.4 AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

FROM oven/bun:1.4-distroless AS runtime
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER 1000:1000
ENV NODE_ENV=production PORT=3000
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/bun", "dist/index.js"]
```

```gitignore
*
!package.json
!bun.lock
!tsconfig.json
!src/
```

```yaml
# .infrastructure/application.yaml: the migration, as an argv
spec:
  migrate: ["/usr/local/bin/bun", "node_modules/prisma/build/index.js", "migrate", "deploy"]
```

On Node, the runtime is `gcr.io/distroless/nodejs24-debian13:nonroot`, the
build stages `node:24-trixie-slim`, and the entrypoint starts with
`/nodejs/bin/node` (signews-api).

## Traps

- **Native libraries.** Distroless carries glibc and little else. A prebuilt
  engine that links more (Prisma 6's engines link OpenSSL, libgcc_s, zlib,
  zstd) gets those libraries copied from a build stage of the same Debian
  release; `ldd` in that stage names them.
- **Writable paths.** The image's files belong to root unless copied with
  `--chown=1000:1000`. A process that writes beside its binary needs that
  directory owned by 1000; data belongs on the chart's `storage:` volume.
- **A tool that downloads on first run** (Prisma's engines) is run once in the
  build, or it tries to write into a `node_modules` it does not own.
