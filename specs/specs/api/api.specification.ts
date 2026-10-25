import { specification } from '@jterrazz/test';
import { afterAll } from 'vitest';

import { discoverRoutes } from '../__setup__/routes.ts';
import type { Route } from '../__setup__/routes.ts';

// value: a cold Next.js pod can take seconds to answer its first request. Every request names
// its host whole, so the url is only where a bare path would go.
export const { api, cleanup } = await specification.api({
    timeout: 15_000,
    url: 'https://www.jterrazz.com',
});

afterAll(cleanup);

/** Every host the live IngressRoutes serve, read off the cluster (or the tailnet job's snapshot) before the run. */
export const routes: Route[] = await discoverRoutes();

const probed = routes.filter((route) => route.contract !== 'opted out');

/** The routes the internet may reach, each with the contract it states. */
export const publicRoutes = probed.filter((route) => !route.private);

/** The routes only the tailnet may reach. */
export const privateRoutes = probed.filter((route) => route.private);

const hostsOf = (selected: Route[]): string[] =>
    [...new Set(selected.map((route) => route.host))].toSorted();

/** Each public host once: several routes share one, and one certificate covers several. */
export const publicHosts = hostsOf(routes.filter((route) => !route.private));

/** Each tailnet-only host once. */
export const privateHosts = hostsOf(routes.filter((route) => route.private));

// outside: cert-manager renews at 30 days left, so 15 means renewal has failed for two weeks.
const MINIMUM_DAYS = 15;

/** What a host's certificate shows over TLS: trusted, covering the host, and far enough from expiry. */
export async function certificateOf(
    host: string,
): Promise<{ authorized: boolean | undefined; covers: boolean | undefined; margin: string }> {
    const result = await api.get(`https://${host}/`);
    const days = result.tls?.daysRemaining ?? 0;

    return {
        authorized: result.tls?.authorized,
        covers: result.tls?.covers(host),
        margin: days >= MINIMUM_DAYS ? 'enough' : `${String(days)} days`,
    };
}

/** What every certificate must show. */
export const SOUND_CERTIFICATE = { authorized: true, covers: true, margin: 'enough' };
