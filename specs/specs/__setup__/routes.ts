import { readFileSync } from 'node:fs';

import { isKubeList, kubectlList } from './kubectl.ts';
import type { KubeList, KubeObject } from './kubectl.ts';

/** What one route's smoke contract asks of its host, read off its `smoke.jterrazz.com/*` annotations. */
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
    /** Tailnet-only: behind the private-access allow-list, or in a private zone. */
    private: boolean;
    probe: Probe;
};

type IngressRoute = KubeObject & {
    spec?: { routes?: { match?: string; middlewares?: { name?: string }[] }[] };
};

const ANNOTATION = 'smoke.jterrazz.com/';
const HOST = /Host\(`(?<host>[^`]+)`\)/gu;

// invariant: the middleware is the enforcement; the zones catch a route whose gate was dropped.
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
// vantage cannot reach the apiserver, so it probes the snapshot the tailnet job took (smoke.yaml).
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
    const gated = rules.some((rule) =>
        (rule.middlewares ?? []).some((middleware) => middleware.name === 'private-access'),
    );
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
