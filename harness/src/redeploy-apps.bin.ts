import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { parseArgs } from 'node:util';

import { kubectlList } from './cluster/kubectl.ts';
import type { KubeList } from './cluster/kubectl.ts';
import { fleetOf, snapshotOf } from './fleet/fleet.ts';

const USAGE = `Usage: make redeploy-apps [ARGS="--dry-run | --from FILE"]

Dispatches every app repository's "Build and Deploy" workflow, so a rebuilt
cluster gets its apps back. The fleet is DISCOVERED: each app Deployment names
its repository in app.jterrazz.com/repository. A repaved cluster has none to
read, so snapshot it before the destroy and replay the file after:

  --dry-run     print one repository per line on stdout, dispatch nothing
  --from FILE   dispatch the repositories FILE lists instead of discovering
`;

// invariant: the workflow name every app repository exposes; a dispatch is addressed by name.
const WORKFLOW = 'Build and Deploy';

// invariant: rolling deploys against ONE memory-constrained node; without a gap every run lands at once.
const STAGGER_MS = 20_000;

const { values } = parseArgs({
    options: {
        'dry-run': { type: 'boolean' },
        from: { type: 'string' },
        help: { short: 'h', type: 'boolean' },
    },
});

if (values.help === true) {
    process.stdout.write(USAGE);
    process.exit(0);
}

const repositories = values.from === undefined ? await discover() : replay(values.from);

if (repositories.length === 0) {
    fail("found no repositories: a broken query or an empty file, never 'no apps'");
}

if (values['dry-run'] === true) {
    process.stdout.write(`${repositories.join('\n')}\n`);
    process.stderr.write(
        `${String(repositories.length)} repositories would be dispatched (--dry-run: nothing sent)\n`,
    );
    process.exit(0);
}

for (const [index, repository] of repositories.entries()) {
    const dispatched = await dispatch(repository);
    process.stderr.write(
        dispatched
            ? `dispatched ${repository}: https://github.com/${repository}/actions\n`
            : `could not dispatch ${repository} (does it have a "${WORKFLOW}" workflow yet?)\n`,
    );
    if (index < repositories.length - 1) {
        await sleep(STAGGER_MS);
    }
}

function replay(file: string): string[] {
    process.stderr.write(`replaying ${file}\n`);

    return snapshotOf(readFileSync(file, 'utf8'));
}

async function discover(): Promise<string[]> {
    process.stderr.write('discovering the fleet from the cluster\n');
    let namespaces: KubeList;
    let deployments: KubeList;
    try {
        namespaces = await kubectlList(['namespaces']);
        deployments = await kubectlList(['deployments', '--all-namespaces']);
    } catch (error) {
        fail(
            `${error instanceof Error ? error.message : String(error)}\n` +
                'A freshly repaved cluster has no app Deployments: replay the snapshot with --from.',
        );
    }
    const fleet = fleetOf(namespaces, deployments);
    if (fleet.unannotated.length > 0) {
        fail(
            `${String(fleet.unannotated.length)} app Deployments name no repository (app.jterrazz.com/repository):\n${fleet.unannotated
                .map((where) => `  - ${where}\n`)
                .join(
                    '',
                )}Redeploy each once from its own CI (gh workflow run '${WORKFLOW}' --repo <owner>/<repo>); ` +
                `docker-deploy passes --set meta.repository, which the chart stamps.`,
        );
    }

    return fleet.repositories;
}

async function dispatch(repository: string): Promise<boolean> {
    return await new Promise((resolve) => {
        execFile('gh', ['workflow', 'run', WORKFLOW, '--repo', repository], (error) => {
            resolve(error === null);
        });
    });
}

function fail(message: string): never {
    process.stderr.write(`${message}\n`);
    process.exit(1);
}
