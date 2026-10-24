import type { KubeList, KubeObject } from '../cluster/kubectl.ts';

/**
 * One key, two meanings: as a namespace LABEL it is the bare name of the repository
 * that owns the namespace; as a Deployment ANNOTATION it is `<owner>/<repo>`, which
 * the app chart stamps from docker-deploy's `meta.repository`.
 */
export const REPOSITORY_KEY = 'app.jterrazz.com/repository';

/** What the cluster says about its apps: the repositories to rebuild, and the Deployments that name none. */
export type Fleet = { repositories: string[]; unannotated: string[] };

/**
 * The fleet, read off the live objects: every Deployment in a namespace an app owns
 * (labelled app.jterrazz.com/repository) names its repository in an annotation.
 * Platform services render through the same chart, but live in the platform
 * namespaces, which no app owns, so they are not part of the fleet.
 */
export function fleetOf(namespaces: KubeList, deployments: KubeList): Fleet {
    const owned = new Set(
        namespaces.items
            .filter((namespace) => (namespace.metadata.labels?.[REPOSITORY_KEY] ?? '') !== '')
            .map((namespace) => namespace.metadata.name),
    );
    const repositories = new Set<string>();
    const unannotated: string[] = [];
    for (const deployment of deployments.items) {
        if (!owned.has(deployment.metadata.namespace ?? '')) {
            continue;
        }
        const repository = deployment.metadata.annotations?.[REPOSITORY_KEY]?.trim() ?? '';
        if (repository === '') {
            unannotated.push(where(deployment));
        } else {
            repositories.add(repository);
        }
    }

    return { repositories: [...repositories].toSorted(), unannotated: unannotated.toSorted() };
}

/** The repositories a snapshot file holds: one per line, `#` comments and blank lines dropped. */
export function snapshotOf(text: string): string[] {
    return text
        .split('\n')
        .map((line) => line.replace(/#.*/u, '').trim())
        .filter((line) => line !== '');
}

const where = (object: KubeObject): string =>
    `${object.metadata.namespace ?? '?'}/${object.metadata.name}`;
