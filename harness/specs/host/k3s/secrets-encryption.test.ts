import { describe, expect, test } from 'vitest';

import { onHost } from '../__setup__/shell.ts';

describe('secrets-encryption', () => {
    test('k3s encrypts secrets at rest, every server on the same key', async () => {
        // Given - what k3s reports of its encryption provider
        const status = await onHost(['k3s', 'secrets-encrypt', 'status']);
        const reported = new Map(
            status.stdout.split('\n').map((line): [string, string] => {
                const [key = '', ...value] = line.split(': ');

                return [key, value.join(': ')];
            }),
        );

        // Then - enabled, and the hashes agree; the rotation stage is left free, a rotation moves it
        expect({
            encryption: reported.get('Encryption Status'),
            hashes: reported.get('Server Encryption Hashes'),
        }).toStrictEqual({ encryption: 'Enabled', hashes: 'All hashes match' });
    });
});
