import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeObject } from '../../__setup__/kubectl.ts';

type IngressRoute = KubeObject & {
    spec: { entryPoints?: string[]; routes?: { match?: string }[]; tls?: object };
};

const HOST = /Host\(`(?<host>[^`]+)`\)/gu;
const PRIVATE_ZONES = ['.internal.', '.staging.'];
const TARGET = 'external-dns.alpha.kubernetes.io/target';

describe('entrypoints', () => {
    test('every route sits on one entrypoint, and the tunnel holds public hosts alone', async () => {
        // Given - every IngressRoute; cloudflared reaches the tunnel entrypoint alone (allow-traefik-ingress)
        const routes = await kubectlList<IngressRoute>([
            'ingressroutes.traefik.io',
            '--all-namespaces',
        ]);

        // When - each is read for its entrypoints, its hosts, its TLS and its external-dns target
        const violations = routes.items.flatMap(({ metadata, spec }) => {
            const where = `${metadata.namespace ?? ''}/${metadata.name}`;
            const entryPoints = spec.entryPoints ?? [];
            const onTunnel = entryPoints.includes('tunnel');
            const hosts = (spec.routes ?? []).flatMap((rule) =>
                [...(rule.match ?? '').matchAll(HOST)].map((found) => found.groups?.host ?? ''),
            );
            const published = metadata.annotations?.[TARGET] !== undefined;

            return [
                ...(entryPoints.length === 1 &&
                ['tunnel', 'websecure'].includes(entryPoints[0] ?? '')
                    ? []
                    : [
                          `${where}: entrypoints ${JSON.stringify(entryPoints)}, not tunnel or websecure alone`,
                      ]),
                ...hosts
                    .filter((host) => onTunnel && PRIVATE_ZONES.some((zone) => host.includes(zone)))
                    .map((host) => `${where}: private host ${host} on the tunnel`),
                ...(onTunnel && spec.tls !== undefined
                    ? [`${where}: TLS on the tunnel, which never matches its plain HTTP`]
                    : []),
                ...(onTunnel === published
                    ? []
                    : [
                          `${where}: on the tunnel ${String(onTunnel)}, published ${String(published)}`,
                      ]),
            ];
        });

        // Then - none: a request that crossed Cloudflare has no private route to match, and every public route has its record
        expect(violations).toStrictEqual([]);
    });
});
