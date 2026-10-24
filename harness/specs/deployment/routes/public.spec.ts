import { describe, expect, test } from 'vitest';

import { deployment, publicRoutes } from '../deployment.specification.ts';
import { contractGolden, exchange } from './__setup__/exchange.ts';

describe('public', () => {
    test.each(publicRoutes)(
        '$host$probe.path answers its contract ($origin, $contract)',
        async (route) => {
            // Given - a public route, asked what its smoke.jterrazz.com/* annotations say, through the Cloudflare tunnel
            const result = await exchange(deployment, route);

            // Then - a status the contract accepts, and the Location it names; a redirect is the answer, never followed
            expect(result.response).toMatch(contractGolden(route, result.response.status));
        },
    );
});
