import { describe, expect, test } from 'vitest';

import { onHost } from '../__setup__/shell.ts';

const ASKED = new Set([
    'kbdinteractiveauthentication',
    'passwordauthentication',
    'permitemptypasswords',
    'permitrootlogin',
    'pubkeyauthentication',
]);

describe('config', () => {
    test('sshd effectively takes keys alone, root included', async () => {
        // Given - the configuration sshd runs with, every drop-in resolved (`sshd -T`)
        const effective = await onHost(['sshd', '-T']);
        const settings = Object.fromEntries(
            effective.stdout
                .split('\n')
                .map((line): [string, string] => {
                    const [key = '', ...value] = line.trim().split(' ');

                    return [key, value.join(' ')];
                })
                .filter(([key]) => ASKED.has(key)),
        );

        // Then - no password and no keyboard-interactive path, root by key only (`sshd -T` prints prohibit-password by its older name, without-password)
        expect({ code: effective.code, settings }).toStrictEqual({
            code: 0,
            settings: {
                kbdinteractiveauthentication: 'no',
                passwordauthentication: 'no',
                permitemptypasswords: 'no',
                permitrootlogin: 'without-password',
                pubkeyauthentication: 'yes',
            },
        });
    });
});
