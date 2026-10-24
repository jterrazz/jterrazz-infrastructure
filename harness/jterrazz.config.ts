import { test } from '@jterrazz/test/config';
import { defineConfig } from '@jterrazz/typescript/config';

export default defineConfig({
    kind: 'cli',
    platform: 'node',
    presets: [test()],
    typescript: {
        knip: {
            ignoreDependencies: {
                yaml: 'the specs read group_vars and role defaults with the yaml @jterrazz/test carries, which its no-redundant-test-dependency rule forbids a member to declare again',
            },
        },
    },
});
