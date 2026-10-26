import { execFile } from 'node:child_process';

/** What one command on the node answered: its exit code and both streams, never thrown. */
export type HostOutcome = { code: number; stderr: string; stdout: string };

// invariant: HOST_SHELL is the command line that runs a command as root on the node: the Mac's
// `orb -m studio-infrastructure -u root`, CI's `ssh -i <deploy key> ... root@<node>`. ssh joins
// the words into one remote line, so every command here is plain words, no shell syntax.
/** Runs one command as root on the node, `input` on its stdin. */
export async function onHost(command: readonly string[], input = ''): Promise<HostOutcome> {
    const shell = (process.env.HOST_SHELL ?? '').trim();
    if (shell === '') {
        throw new Error(
            'HOST_SHELL is not set: `orb -m studio-infrastructure -u root` from the Mac, ' +
                '`ssh -i <key> root@<node>` from CI',
        );
    }
    const [program = '', ...prefix] = shell.split(/\s+/u);

    return await new Promise((resolve) => {
        const child = execFile(program, [...prefix, ...command], (error, stdout, stderr) => {
            resolve({ code: exitCodeOf(error), stderr, stdout });
        });
        child.stdin?.end(input);
    });
}

// value: a program that never started (ENOENT) reports a string code; 127 is the shell's word for it.
function exitCodeOf(error: null | { code?: null | number | string }): number {
    if (error === null) {
        return 0;
    }

    return typeof error.code === 'number' ? error.code : 127;
}
