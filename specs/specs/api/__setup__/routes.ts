import { readFileSync } from 'node:fs';

import { isKubeList, kubectlList } from '../../__setup__/kubectl.ts';
import type { KubeList, KubeObject } from '../../__setup__/kubectl.ts';

/** What one route's smoke contract asks of its host, read off its `studio.jterrazz.com/smoke-*` annotations. */
export type Probe = {
    expect: number[];
    location: string | undefined;
    method: string;
    path: string;
};

/** One host an IngressRoute serves, the contract it states, and who may reach it. */
export type Route = {
    /** `annotated`, the fallback `GET / -> 200` of a route that states nothing, or `opted out`. */
    contract: 'annotated' | 'fallback' | 'opted out';
    host: string;
    /** `<namespace>/<name>` of the IngressRoute. */
    origin: string;
    /** Tailnet-only: off the tunnel entrypoint, or in a private zone. */
    private: boolean;
    probe: Probe;
};

type IngressRoute = KubeObject & {
    spec?: { entryPoints?: string[]; routes?: { match?: string }[] };
};

const ANNOTATION = 'studio.jterrazz.com/smoke-';
const HOST = /Host\(`(?<host>[^`]+)`\)/gu;

// invariant: the entrypoint is the enforcement; the zones catch a private host put on the tunnel.
const PRIVATE_ZONES = ['.internal.', '.staging.'];

/** Every host the live IngressRoutes serve, each with its contract; zero routes is a broken cluster, never an empty list. */
export async function discoverRoutes(): Promise<Route[]> {
    const listed = await listIngressRoutes();
    const routes = listed.items.flatMap(routesOf);
    if (routes.length === 0) {
        throw new Error(
            'the cluster returned no IngressRoute host at all: a broken cluster or a broken query, never "nothing to check"',
        );
    }

    return routes;
}

// invariant: INGRESSROUTES_FILE is a `kubectl get ingressroutes -o json` taken elsewhere: the internet
// vantage cannot reach the apiserver, so it probes the snapshot the tailnet job took (watch.yaml).
async function listIngressRoutes(): Promise<KubeList<IngressRoute>> {
    const snapshot = process.env.INGRESSROUTES_FILE ?? '';
    if (snapshot === '') {
        return await kubectlList<IngressRoute>(['ingressroutes.traefik.io', '--all-namespaces']);
    }
    const parsed: unknown = JSON.parse(readFileSync(snapshot, 'utf8'));
    if (!isKubeList<IngressRoute>(parsed)) {
        throw new Error(`${snapshot} holds no IngressRoute list`);
    }

    return parsed;
}

function routesOf(object: IngressRoute): Route[] {
    const annotations = object.metadata.annotations ?? {};
    const declared = (key: string): string | undefined => annotations[`${ANNOTATION}${key}`];
    const rules = object.spec?.routes ?? [];
    const gated = !(object.spec?.entryPoints ?? []).includes('tunnel');
    const hosts = new Set(
        rules.flatMap((rule) =>
            [...(rule.match ?? '').matchAll(HOST)].map((found) => found.groups?.host ?? ''),
        ),
    );
    const path = declared('path') ?? '/';
    const probe: Probe = {
        expect: (declared('expect') ?? '200').split(',').map(Number),
        location: declared('location'),
        method: declared('method') ?? 'GET',
        path: path.startsWith('/') ? path : `/${path}`,
    };

    return [...hosts]
        .filter((host) => host !== '')
        .map((host) => ({
            contract: contractOf(declared),
            host,
            origin: `${object.metadata.namespace ?? '?'}/${object.metadata.name}`,
            private: gated || PRIVATE_ZONES.some((zone) => host.includes(zone)),
            probe,
        }));
}

function contractOf(declared: (key: string) => string | undefined): Route['contract'] {
    if (declared('probe')?.toLowerCase() === 'false') {
        return 'opted out';
    }

    return declared('expect') === undefined && declared('path') === undefined
        ? 'fallback'
        : 'annotated';
}
