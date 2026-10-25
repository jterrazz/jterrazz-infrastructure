import type { ApiDeployedSpecification, ExchangeResult } from '@jterrazz/test';

import type { Route } from '../../__setup__/routes.ts';

// invariant: a POST probe sends an empty JSON object: without a JSON content type the ingest
// endpoint answers 415 before it reads anything, a pass for the wrong reason.
/** Sends the request a route's contract states, to its host, over the network. */
export async function exchange(
    api: ApiDeployedSpecification,
    { host, probe }: Route,
): Promise<ExchangeResult> {
    const url = `https://${host}${probe.path}`;
    if (probe.method === 'GET') {
        return await api.get(url);
    }

    return await api.request(`${probe.method} ${url}\ncontent-type: application/json\n\n{}`);
}

/** The golden a route's contract states, at the status that came back when the contract accepts it, so a diff shows the one that came. */
export function contractGolden({ probe }: Route, answered: number): string {
    const status = probe.expect.includes(answered) ? answered : (probe.expect[0] ?? 200);

    return probe.location === undefined
        ? `HTTP/1.1 ${String(status)}`
        : `HTTP/1.1 ${String(status)}\nlocation: ${probe.location}`;
}
