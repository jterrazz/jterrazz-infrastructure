import { describe, expect, test } from 'vitest';

import { api, privateHosts } from '../api.specification.ts';

// outside: cert-manager renews at 30 days left, so 15 means renewal has failed for two weeks.
const MINIMUM_DAYS = 15;

describe('private', () => {
    test.each(privateHosts)(
        '%s presents a trusted certificate that covers it, 15 days from expiry or more',
        async (host) => {
            // Given - the tailnet-only host, asked over TLS from the tailnet
            const result = await api.get(`https://${host}/`);

            // Then - a certificate the system trusts, naming this host, with the margin
            expect({
                authorized: result.tls?.authorized,
                covers: result.tls?.covers(host),
                margin:
                    (result.tls?.daysRemaining ?? 0) >= MINIMUM_DAYS
                        ? 'enough'
                        : `${String(result.tls?.daysRemaining)} days`,
            }).toStrictEqual({ authorized: true, covers: true, margin: 'enough' });
        },
    );
});
