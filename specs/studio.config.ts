import { test } from '@jterrazz/test/config';
import { defineConfig } from '@jterrazz/typescript/config';

export default defineConfig({
    kind: 'cli',
    platform: 'node',
    presets: [test()],
    test: {
        projects: {
            api: {
                reason: 'this project is itself the specs/ folder of the repository, which @jterrazz/test 18.3 reads as a workspace member and derives no api project for',
                runner: './specs/api/api.specification.ts',
            },
        },
    },
    typescript: {
        knip: {
            ignoreDependencies: {
                yaml: 'the specs read group_vars and role defaults with the yaml @jterrazz/test carries, which its no-redundant-test-dependency rule forbids a member to declare again',
            },
        },
    },
});
