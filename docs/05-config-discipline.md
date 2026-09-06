# Config discipline

The best comment is a deleted line of config. Apply these five rules
mechanically when editing any values file, manifest or template in this repo.

1. **Check the upstream default before writing a comment that justifies a
   value** (`helm show values <chart> --version <pin>`, the binary's `--help`,
   the Kubernetes API defaults). If your value equals the default, delete the
   value and the comment — a restated default is a line that reads as a
   decision and is not one. If it differs, keep it and write one sentence
   naming the default and the reason for diverging.
2. **A knob nothing sets is dead weight, and its comment is pure cost.** Grep
   before adding a values key; if no consumer sets it, it does not belong in
   the chart. Never default the same key in two places either — a `| default`
   in a template whose key already has a value in `values.yaml` can never fire,
   so `values.yaml` owns defaults and templates read them plainly.
3. **Prefer the default when it fails faster, uses less memory, or is one fewer
   moving part**, and state the improvement in numbers. A `failureThreshold: 30`
   on the Kubernetes default 10s period buys the same 300s of grace as
   `5s × 60`, at half the probe traffic and one fewer override.
4. **A comment's subject must be a live invariant, not history.** The keep-bar
   is one of three: a cross-resource invariant (this name must match that one),
   a data-destroying constraint (change this and the volume is orphaned), or a
   silent-failure trap (the wrong spelling applies cleanly and does nothing).
   Delete past measurements, incident narratives, dated right-sizing diaries,
   completed-migration tables and verification transcripts — git history keeps
   them, and a comment nobody can re-verify becomes a comment nobody trusts.
5. **Say it once.** One file owns each rationale and the others point at it.
   When you delete a value, grep the tree for comments that reference it: a
   dangling "see the note in X" is worse than no note at all.
