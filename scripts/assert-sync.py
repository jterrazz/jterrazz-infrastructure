#!/usr/bin/env python3
"""Assert the cross-file invariants this repo cannot express in one place.

Several facts in this repo are necessarily written down twice, in two
different languages, because two different machines consume them (a Traefik
entrypoint argument and a Traefik Middleware CRD; a Python secret map and an
Ansible assert block; a bash release table and the Ansible tasks that deploy
it). Each pair carries a "KEEP IN SYNC" comment, and a comment is not a check.
This script is the check.

Run it:
    python3 scripts/assert-sync.py

Exit status is 0 only if every check passes; a failing check prints exactly
what to edit. It runs in `make check` and in the `scripts` job of
.github/workflows/validate.yaml.

DESIGN NOTES
------------
* Stdlib only, on purpose. It has to run on a bare `ubuntu-latest` runner in
  the `scripts` job, which installs nothing (that job is deliberately the fast
  one) — so no PyYAML, no ruamel. The YAML this reads is a handful of flat
  block lists/maps, which a ~40-line parser handles exactly; anything more
  exotic than that in those files should fail loudly here rather than be
  silently half-parsed. Hence `_block_list` / `_block_map` raise on a missing
  key rather than returning empty.
* infisical-vars.py is read with `ast`, not regex: it is Python, so the real
  parser is free and exact.
"""

import ast
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GROUP_VARS = "ansible/inventories/group_vars/all.yml"
INFISICAL_VARS = "scripts/infisical-vars.py"
PREFLIGHT = "ansible/roles/platform/tasks/preflight.yml"
TRAEFIK_CONFIG = "kubernetes/cluster/traefik/traefik-config.yaml"
MIDDLEWARE = "kubernetes/cluster/traefik/middleware.yaml"
PLATFORM_TASKS = "ansible/roles/platform/tasks"
PLATFORM_DIFF = "scripts/platform-diff.sh"
SERVICE_CHARTS = "ansible/roles/platform/tasks/service-charts.yml"
SMOKE = "scripts/smoke.sh"
MAKEFILE = "Makefile"
VALIDATE_WF = ".github/workflows/validate.yaml"
PUBLISH_WF = ".github/workflows/publish-chart.yaml"
DEPLOY_WF = ".github/workflows/deploy-platform.yaml"
TRIGGER_DEPLOYS = "scripts/trigger-app-deploys.sh"
PUBLISH_SCRIPT = "scripts/publish-app-chart.sh"
ANSIBLE_PUBLISH = "ansible/roles/platform/tasks/publish-app-chart.yml"


# ---------------------------------------------------------------------------
# Tiny readers
# ---------------------------------------------------------------------------

class SyncError(Exception):
    """A check could not even be evaluated (a file or key moved/renamed)."""


def read(relpath):
    path = os.path.join(REPO, relpath)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise SyncError(f"cannot read {relpath}: {exc}") from exc


def _strip_comment(value):
    """Drop a trailing `# ...` comment from a YAML scalar line.

    Only a `#` preceded by whitespace starts a comment in YAML, so
    `10.42.0.0/16 # k3s pod CIDR` loses the comment while a `#` inside a value
    would not. Quotes are stripped afterwards by the caller.
    """
    match = re.search(r"\s+#", value)
    if match:
        value = value[: match.start()]
    return value.strip()


def _unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _block_body(text, key, source):
    """Return the indented lines that follow a top-level `key:` line."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}\s*:\s*$", line):
            start = index + 1
            break
    if start is None:
        raise SyncError(
            f"{source}: no top-level `{key}:` block. If it was renamed or "
            f"restructured, update scripts/assert-sync.py alongside it."
        )
    body = []
    for line in lines[start:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace():
            break
        body.append(line)
    return body


def block_list(text, key, source):
    """Parse a flat YAML block sequence: `key:` then `  - value` lines."""
    out = []
    for line in _block_body(text, key, source):
        stripped = line.strip()
        if not stripped.startswith("- "):
            raise SyncError(
                f"{source}: `{key}:` is not a flat list of `- value` entries "
                f"(offending line: {stripped!r}). assert-sync.py's parser is "
                f"deliberately narrow — extend it or simplify the file."
            )
        out.append(_unquote(_strip_comment(stripped[2:])))
    return out


def block_map(text, key, source):
    """Parse a flat YAML block mapping: `key:` then `  name: value` lines."""
    out = {}
    for line in _block_body(text, key, source):
        stripped = line.strip()
        if ":" not in stripped:
            raise SyncError(
                f"{source}: `{key}:` is not a flat `name: value` mapping "
                f"(offending line: {stripped!r})."
            )
        name, _, value = stripped.partition(":")
        out[name.strip()] = _unquote(_strip_comment(value))
    return out


def block_scalar(text, key, source):
    """Read a top-level `key: value` scalar out of a YAML file."""
    match = re.search(rf"^{re.escape(key)}\s*:\s*(\S.*)$", text, re.MULTILINE)
    if not match:
        raise SyncError(
            f"{source}: no top-level `{key}:` scalar. It was renamed or moved "
            f"— update scripts/assert-sync.py alongside it."
        )
    return _unquote(_strip_comment(match.group(1)))


def bash_array(text, name, source):
    """Read a `NAME=( "a|b" ... )` bash array of quoted strings."""
    match = re.search(
        rf"^{re.escape(name)}=\((?P<body>.*?)^\)\s*$", text, re.MULTILINE | re.DOTALL
    )
    if not match:
        raise SyncError(
            f"{source}: no `{name}=( ... )` array literal. It was renamed or "
            f"restructured — update scripts/assert-sync.py so the two files "
            f"stay verifiably in sync."
        )
    entries = []
    for line in match.group("body").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        item = re.match(r'^"(?P<value>[^"]*)"$', stripped)
        if not item:
            raise SyncError(
                f"{source}: `{name}` entry is not a single double-quoted "
                f"string ({stripped!r}). assert-sync.py's parser is "
                f"deliberately narrow — keep the table flat."
            )
        entries.append(item.group("value"))
    return entries


def _collapse_jinja(text):
    """`{{ manifest_dir }}/x` -> `{{manifest_dir}}/x`, so it survives split()."""
    return re.sub(r"\{\{\s*(.*?)\s*\}\}", r"{{\1}}", text)


def ansible_commands(text):
    """Flatten every ansible.builtin.command/shell in a task file to one line.

    Handles the three shapes this role uses: an inline `command: helm ...`, a
    folded `command: >` block, and the `argv:` list form (used where a secret
    must never touch a shell). Everything else is ignored — the callers only
    look for `helm upgrade --install` in the result.
    """
    lines = _collapse_jinja(text).splitlines()
    out = []
    index = 0
    while index < len(lines):
        line = lines[index]
        folded = re.match(r"^(?P<indent>\s*)ansible\.builtin\.(command|shell):\s*>-?\s*$", line)
        argv = re.match(r"^(?P<indent>\s*)argv:\s*$", line)
        inline = re.match(
            r"^\s*ansible\.builtin\.(command|shell):\s*(?P<body>\S.*)$", line
        )
        if folded:
            base = len(folded.group("indent"))
            parts = []
            index += 1
            while index < len(lines):
                nxt = lines[index]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= base:
                    break
                parts.append(nxt.strip())
                index += 1
            out.append(" ".join(p for p in parts if p))
            continue
        if argv:
            base = len(argv.group("indent"))
            parts = []
            index += 1
            while index < len(lines):
                nxt = lines[index]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= base:
                    break
                item = re.match(r"^\s*-\s+(?P<value>.*)$", nxt)
                if item:
                    parts.append(_unquote(item.group("value").strip()))
                index += 1
            out.append(" ".join(parts))
            continue
        if inline and inline.group("body") not in (">", ">-", "|"):
            out.append(inline.group("body").strip())
        index += 1
    return out


def _flag_value(tokens, flag):
    """The token after `flag`, unquoted; None if the flag is absent."""
    for position, token in enumerate(tokens):
        if token == flag and position + 1 < len(tokens):
            return _unquote(tokens[position + 1])
    return None


# ---------------------------------------------------------------------------
# Checks. Each returns a list of human-readable problems (empty == pass).
# ---------------------------------------------------------------------------

def check_secret_keys():
    """The Infisical var map (Python) vs the Ansible preflight assert.

    infisical-vars.py writes exactly one extra-vars file; preflight.yml is the
    gate that refuses to deploy without those vars. A var fetched but not
    asserted has no gate; a var asserted but not fetched fails every deploy.

    Scoped to the PLATFORM scope, because preflight.yml lives in
    roles/platform and both playbooks reach it through that role: site.yml
    imports platform.yml, and .github/workflows/deploy-platform.yaml runs
    platform.yml alone. The site-only extras (the Tailscale OAuth pair) are
    consumed by roles/tailscale, never by the platform role, so asserting them
    here would break every CI platform deploy — which is exactly why the scope
    is read out of SCOPES rather than hardcoded.
    """
    problems = []
    src = read(INFISICAL_VARS)
    tree = ast.parse(src, INFISICAL_VARS)

    maps = {}
    scopes_node = None
    written_directly = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            # <NAME>_VARS = { "<ansible var>": (secret path, key at that path) }
            if isinstance(target, ast.Name) and target.id.endswith("_VARS"):
                if not isinstance(node.value, ast.Dict):
                    raise SyncError(
                        f"{INFISICAL_VARS}: {target.id} is no longer a dict "
                        f"literal — update scripts/assert-sync.py."
                    )
                keys = set()
                for key in node.value.keys:
                    if not isinstance(key, ast.Constant):
                        raise SyncError(
                            f"{INFISICAL_VARS}: {target.id} has a computed key; "
                            f"assert-sync.py can only read literals."
                        )
                    keys.add(key.value)
                maps[target.id] = keys
            if isinstance(target, ast.Name) and target.id == "SCOPES":
                scopes_node = node.value
            # The credentials the script writes itself (chicken-and-egg: the
            # in-cluster operator needs them and they cannot come from
            # Infisical). Shape: out["infisical_client_id"] = client_id
            if (
                isinstance(target, ast.Subscript)
                and isinstance(target.value, ast.Name)
                and target.value.id == "out"
                and isinstance(target.slice, ast.Constant)
            ):
                written_directly.add(target.slice.value)

    if not maps or scopes_node is None:
        raise SyncError(
            f"{INFISICAL_VARS}: no `*_VARS` dict literal and/or no `SCOPES` "
            f"map found. The secret map was renamed or restructured — update "
            f"scripts/assert-sync.py."
        )
    if not isinstance(scopes_node, ast.Dict):
        raise SyncError(f"{INFISICAL_VARS}: SCOPES is not a dict literal.")

    platform_value = None
    for key, value in zip(scopes_node.keys, scopes_node.values):
        if isinstance(key, ast.Constant) and key.value == "platform":
            platform_value = value
    if platform_value is None:
        raise SyncError(
            f"{INFISICAL_VARS}: SCOPES has no \"platform\" entry, but "
            f"{PREFLIGHT} gates the platform play. Update both together."
        )

    def scope_keys(node):
        """Resolve a SCOPES value: `COMMON_VARS` or `{**A, **B}`."""
        if isinstance(node, ast.Name):
            if node.id not in maps:
                raise SyncError(
                    f"{INFISICAL_VARS}: SCOPES['platform'] references unknown "
                    f"map {node.id}."
                )
            return set(maps[node.id])
        if isinstance(node, ast.Dict):
            out = set()
            for key, value in zip(node.keys, node.values):
                if key is None:  # `**OTHER_MAP`
                    out |= scope_keys(value)
                elif isinstance(key, ast.Constant):
                    out.add(key.value)
                else:
                    raise SyncError(
                        f"{INFISICAL_VARS}: computed key in SCOPES['platform']."
                    )
            return out
        raise SyncError(
            f"{INFISICAL_VARS}: SCOPES['platform'] is an expression "
            f"assert-sync.py cannot resolve ({type(node).__name__})."
        )

    produced = scope_keys(platform_value) | written_directly

    # preflight.yml: the `that:` list of `- <var> is defined and <var> | ...`
    preflight = read(PREFLIGHT)
    match = re.search(r"^\s*that:\s*$", preflight, re.MULTILINE)
    if not match:
        raise SyncError(
            f"{PREFLIGHT}: no `that:` block found — the assert task was "
            f"restructured; update scripts/assert-sync.py."
        )
    asserted = set()
    for line in preflight[match.end():].splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("- "):
            break
        name = re.match(r"-\s*([A-Za-z_][A-Za-z0-9_]*)\b", stripped)
        if not name:
            raise SyncError(
                f"{PREFLIGHT}: unparseable assert entry {stripped!r}."
            )
        asserted.add(name.group(1))

    if not asserted:
        raise SyncError(f"{PREFLIGHT}: the `that:` list is empty.")

    unasserted = sorted(produced - asserted)
    unfetched = sorted(asserted - produced)
    if unasserted:
        problems.append(
            f"fetched by {INFISICAL_VARS} but NOT asserted in {PREFLIGHT}: "
            f"{', '.join(unasserted)}.\n"
            f"        FIX: add `- <var> is defined and <var> | length > 0` for "
            f"each to the assert's `that:` list (and name them in fail_msg). "
            f"An unasserted secret fails halfway through a deploy, or worse, "
            f"lets a role default paper over a real Infisical misconfiguration."
        )
    if unfetched:
        problems.append(
            f"asserted in {PREFLIGHT} but NOT produced by {INFISICAL_VARS}: "
            f"{', '.join(unfetched)}.\n"
            f"        FIX: add each to COMMON_VARS (both scopes need it) or "
            f"SITE_ONLY_VARS in {INFISICAL_VARS}, or drop the assert. As it "
            f"stands every platform deploy fails preflight."
        )
    return problems


def check_traefik_trusted_ips():
    """Entrypoint forwardedHeaders.trustedIPs vs rate-limit excludedIPs.

    Both lists answer the same question — "which addresses are OUR hops" —
    for two different Traefik features. trustedIPs decides whether Traefik
    KEEPS the X-Forwarded-For header at all; excludedIPs decides which XFF
    element the rate limiter keys on. A range in one and not the other means
    the limiter either keys on one of our own proxies (one global bucket) or
    on an address Traefik already discarded.
    """
    problems = []

    # traefik-config.yaml embeds the whole Traefik chart config as a
    # `valuesContent: |-` STRING, so this is not addressable YAML. Match the
    # CLI argument itself, wherever it sits and however it is quoted.
    config = read(TRAEFIK_CONFIG)
    match = re.search(
        r"forwardedHeaders\.trustedIPs=([^\"'\s]+)",
        config,
    )
    if not match:
        raise SyncError(
            f"{TRAEFIK_CONFIG}: no "
            f"`--entryPoints.<name>.forwardedHeaders.trustedIPs=` argument. It "
            f"moved out of additionalArguments (or the entrypoint was renamed) "
            f"— update scripts/assert-sync.py."
        )
    trusted = {cidr.strip() for cidr in match.group(1).split(",") if cidr.strip()}

    # middleware.yaml holds several Middleware objects; only the rate-limit
    # one carries excludedIPs, but scope the search to its document anyway so
    # a future second excludedIPs cannot be picked up by accident.
    middleware = read(MIDDLEWARE)
    docs = [d for d in re.split(r"^---\s*$", middleware, flags=re.MULTILINE)]
    rate_limit_docs = [d for d in docs if re.search(r"^\s*name:\s*rate-limit\s*$", d, re.MULTILINE)]
    if len(rate_limit_docs) != 1:
        raise SyncError(
            f"{MIDDLEWARE}: expected exactly one `name: rate-limit` document, "
            f"found {len(rate_limit_docs)} — update scripts/assert-sync.py."
        )
    doc = rate_limit_docs[0]
    start = re.search(r"^(\s*)excludedIPs:\s*$", doc, re.MULTILINE)
    if not start:
        raise SyncError(
            f"{MIDDLEWARE}: the rate-limit middleware has no "
            f"`sourceCriterion.ipStrategy.excludedIPs:` list. If it switched to "
            f"`depth:`, that is a deliberate behaviour change — read the "
            f"comment in {MIDDLEWARE} and update scripts/assert-sync.py."
        )
    indent = len(start.group(1))
    excluded = set()
    for line in doc[start.end():].splitlines():
        if not line.strip():
            continue
        if len(line) - len(line.lstrip()) <= indent:
            break
        stripped = line.strip()
        if not stripped.startswith("- "):
            break
        excluded.add(_unquote(_strip_comment(stripped[2:])))

    only_trusted = sorted(trusted - excluded)
    only_excluded = sorted(excluded - trusted)
    if only_trusted:
        problems.append(
            f"in forwardedHeaders.trustedIPs ({TRAEFIK_CONFIG}) but NOT in the "
            f"rate-limit excludedIPs ({MIDDLEWARE}): {', '.join(only_trusted)}.\n"
            f"        FIX: add them to `excludedIPs`. Traefik trusts XFF from "
            f"these peers, so the limiter can end up keying on one of OUR hops "
            f"— every request through it shares a single bucket."
        )
    if only_excluded:
        problems.append(
            f"in the rate-limit excludedIPs ({MIDDLEWARE}) but NOT in "
            f"forwardedHeaders.trustedIPs ({TRAEFIK_CONFIG}): "
            f"{', '.join(only_excluded)}.\n"
            f"        FIX: add them to the "
            f"`--entryPoints.websecure.forwardedHeaders.trustedIPs=` argument. "
            f"Traefik STRIPS X-Forwarded-* from any peer not in that list, so "
            f"excluding the range here has no effect."
        )
    return problems


def check_chart_version_pins():
    """Every `platform_chart_versions` pin is actually consumed.

    An orphan pin reads as "this chart is pinned" while the install it was
    written for is gone or unpinned — i.e. the next deploy silently adopts
    whatever the upstream repo's latest happens to be that day.
    """
    problems = []
    gv = read(GROUP_VARS)
    pins = block_map(gv, "platform_chart_versions", GROUP_VARS)
    if not pins:
        raise SyncError(f"{GROUP_VARS}: `platform_chart_versions` is empty.")

    tasks_dir = os.path.join(REPO, PLATFORM_TASKS)
    if not os.path.isdir(tasks_dir):
        raise SyncError(f"{PLATFORM_TASKS}: directory not found.")

    corpus = ""
    for name in sorted(os.listdir(tasks_dir)):
        if name.endswith((".yml", ".yaml")):
            corpus += read(os.path.join(PLATFORM_TASKS, name))

    orphans = [
        key
        for key in sorted(pins)
        if not re.search(rf"platform_chart_versions\.{re.escape(key)}\b", corpus)
        and not re.search(
            rf"platform_chart_versions\[\s*['\"]{re.escape(key)}['\"]\s*\]", corpus
        )
    ]
    if orphans:
        problems.append(
            f"pinned in {GROUP_VARS} `platform_chart_versions` but consumed by "
            f"nothing in {PLATFORM_TASKS}/: {', '.join(orphans)}.\n"
            f"        FIX: delete the pin (the service is gone) or add "
            f"`--version {{{{ platform_chart_versions.<key> }}}}` to its "
            f"`helm upgrade --install`. An unpinned install turns an unrelated "
            f"deploy into an uncontrolled upgrade of somebody else's service."
        )
    return problems


def _task_files():
    tasks_dir = os.path.join(REPO, PLATFORM_TASKS)
    if not os.path.isdir(tasks_dir):
        raise SyncError(f"{PLATFORM_TASKS}: directory not found.")
    return [
        os.path.join(PLATFORM_TASKS, name)
        for name in sorted(os.listdir(tasks_dir))
        if name.endswith((".yml", ".yaml"))
    ]


def _ansible_upstream_releases():
    """Every `helm upgrade --install` in roles/platform, as a comparable tuple.

    -> {release: (chart, namespace, version key, values path relative to the
    repo root)}. The service chart's own release is excluded: it is a loop over
    `service_chart_releases`, handled by _ansible_service_releases().
    """
    releases = {}
    for relpath in _task_files():
        if relpath.endswith("service-charts.yml"):
            continue
        for command in ansible_commands(read(relpath)):
            tokens = command.split()
            if "helm" not in tokens or "--install" not in tokens:
                continue
            marker = tokens.index("--install")
            if tokens[:marker].count("upgrade") == 0 or len(tokens) < marker + 3:
                continue
            release = _unquote(tokens[marker + 1])
            chart = _unquote(tokens[marker + 2])
            namespace = _flag_value(tokens, "--namespace")
            version = _flag_value(tokens, "--version")
            values = _flag_value(tokens, "--values")
            if not namespace or not values:
                raise SyncError(
                    f"{relpath}: `helm upgrade --install {release}` has no "
                    f"--namespace and/or --values. assert-sync.py cannot "
                    f"compare it with {PLATFORM_DIFF}."
                )
            key = None
            if version:
                match = re.search(
                    r"platform_chart_versions(?:\.(\w+)|\[\s*['\"](\w+)['\"]\s*\])",
                    version,
                )
                if not match:
                    raise SyncError(
                        f"{relpath}: `--version {version}` for release "
                        f"{release} does not come from "
                        f"`platform_chart_versions` — see check (d)."
                    )
                key = match.group(1) or match.group(2)
            values = values.replace("{{manifest_dir}}/", "")
            releases[release] = (chart, namespace, key, values)
    if not releases:
        raise SyncError(
            f"{PLATFORM_TASKS}: no `helm upgrade --install` found at all. The "
            f"tasks were restructured — update scripts/assert-sync.py."
        )
    return releases


def _ansible_service_releases():
    """The `service_chart_releases` entries every caller passes to the loop."""
    found = {}
    for relpath in _task_files():
        for name, namespace in re.findall(
            r"-\s*\{\s*name:\s*([\w.-]+)\s*,\s*namespace:\s*([\w.-]+)\s*\}",
            read(relpath),
        ):
            found[name] = namespace
    if not found:
        raise SyncError(
            f"{PLATFORM_TASKS}: no `service_chart_releases` entries of the form "
            f"`- {{ name: x, namespace: y }}` found — the callers of "
            f"service-charts.yml were restructured; update assert-sync.py."
        )
    return found


def check_platform_diff_table():
    """scripts/platform-diff.sh's release table vs what Ansible installs.

    platform-diff.sh hand-copies the release inventory so it can preview a
    deploy without running one, and nothing but this check links the two files.
    A stale copy previews a chart the deploy will not install and says "no
    changes" about the one it will.
    """
    problems = []
    diff = read(PLATFORM_DIFF)

    # --- upstream charts -----------------------------------------------------
    table = {}
    for entry in bash_array(diff, "UPSTREAM_RELEASES", PLATFORM_DIFF):
        fields = entry.split("|")
        if len(fields) != 5:
            raise SyncError(
                f"{PLATFORM_DIFF}: UPSTREAM_RELEASES entry {entry!r} has "
                f"{len(fields)} fields, expected 5 "
                f"(release|namespace|chart|version key|values)."
            )
        release, namespace, chart, version_key, values = fields
        table[release] = (chart, namespace, version_key, values)

    ansible = _ansible_upstream_releases()

    only_table = sorted(set(table) - set(ansible))
    only_ansible = sorted(set(ansible) - set(table))
    if only_table:
        problems.append(
            f"in UPSTREAM_RELEASES ({PLATFORM_DIFF}) but installed by nothing "
            f"in {PLATFORM_TASKS}/: {', '.join(only_table)}.\n"
            f"        FIX: delete the line (the release is gone, and `make "
            f"diff` is diffing a chart no deploy installs) or restore the "
            f"`helm upgrade --install`."
        )
    if only_ansible:
        problems.append(
            f"installed by {PLATFORM_TASKS}/ but missing from "
            f"UPSTREAM_RELEASES ({PLATFORM_DIFF}): {', '.join(only_ansible)}.\n"
            f"        FIX: add "
            f"`<release>|<namespace>|<chart>|<version key>|<values file>` to "
            f"the table. Until then `make diff` silently previews less than "
            f"`make deploy-platform` applies."
        )

    for release in sorted(set(table) & set(ansible)):
        labels = ("chart ref", "namespace", "version key", "values file")
        for label, want, got in zip(labels, ansible[release], table[release]):
            if want != got:
                problems.append(
                    f"{release}: {label} is {got!r} in {PLATFORM_DIFF} but "
                    f"{want!r} in {PLATFORM_TASKS}/.\n"
                    f"        FIX: Ansible is the deployer — make "
                    f"{PLATFORM_DIFF} match it."
                )

    # --- the service chart ---------------------------------------------------
    # platform-diff.sh reconstructs these release names and values paths from
    # the service name alone. If the loop's own template changes shape, the
    # table's assumption is wrong in a way no name-by-name comparison sees.
    loop = read(SERVICE_CHARTS)
    expected = [
        "helm upgrade --install {{item.name}}-platform {{service_chart}}",
        "--namespace {{item.namespace}}",
        "--values {{manifest_dir}}/kubernetes/services/{{item.name}}/platform.yaml",
    ]
    loop_command = " ".join(ansible_commands(loop))
    for fragment in expected:
        if fragment not in loop_command:
            raise SyncError(
                f"{SERVICE_CHARTS}: the service-chart install no longer "
                f"contains {fragment!r}. {PLATFORM_DIFF} rebuilds the release "
                f"name and values path from the service name on exactly that "
                f"shape — update both together."
            )

    service_table = {}
    for entry in bash_array(diff, "SERVICE_RELEASES", PLATFORM_DIFF):
        fields = entry.split("|")
        if len(fields) != 2:
            raise SyncError(
                f"{PLATFORM_DIFF}: SERVICE_RELEASES entry {entry!r} has "
                f"{len(fields)} fields, expected 2 (name|namespace)."
            )
        service_table[fields[0]] = fields[1]

    service_ansible = _ansible_service_releases()
    only_table = sorted(set(service_table) - set(service_ansible))
    only_ansible = sorted(set(service_ansible) - set(service_table))
    if only_table:
        problems.append(
            f"in SERVICE_RELEASES ({PLATFORM_DIFF}) but no task passes it to "
            f"service-charts.yml: {', '.join(only_table)}."
        )
    if only_ansible:
        problems.append(
            f"passed to service-charts.yml but missing from SERVICE_RELEASES "
            f"({PLATFORM_DIFF}): {', '.join(only_ansible)}."
        )
    for name in sorted(set(service_table) & set(service_ansible)):
        if service_table[name] != service_ansible[name]:
            problems.append(
                f"{name}-platform: namespace is {service_table[name]!r} in "
                f"{PLATFORM_DIFF} but {service_ansible[name]!r} in "
                f"{PLATFORM_TASKS}/."
            )

    # --- the values files both sides name must exist -------------------------
    for release, (_, _, _, values) in sorted(ansible.items()):
        if not os.path.isfile(os.path.join(REPO, values)):
            problems.append(
                f"{release}: `--values {values}` names a file that does not "
                f"exist. The deploy fails at that task; `make diff` fails at "
                f"the same one."
            )
    for name in sorted(service_ansible):
        values = f"kubernetes/services/{name}/platform.yaml"
        if not os.path.isfile(os.path.join(REPO, values)):
            problems.append(
                f"{name}-platform: {values} does not exist, but "
                f"service-charts.yml renders that path from the release name."
            )
    return problems


def _setup_helm_versions(relpath):
    """Every `version:` given to an `azure/setup-helm` step in a workflow."""
    versions = []
    lines = read(relpath).splitlines()
    for index, line in enumerate(lines):
        if not re.search(r"uses:\s*azure/setup-helm@", line):
            continue
        for follower in lines[index + 1 : index + 10]:
            if re.match(r"^\s*-\s", follower):  # next step
                break
            match = re.match(r"^\s*version:\s*(\S+)\s*$", follower)
            if match:
                versions.append(_unquote(match.group(1)))
                break
    if not versions:
        raise SyncError(
            f"{relpath}: an `azure/setup-helm` step with a `version:` was "
            f"expected and not found. If the workflow stopped installing Helm, "
            f"drop it from this check; otherwise the pin is now floating."
        )
    return versions


def check_helm_version():
    """`helm_version` in group_vars vs the Helm CI installs.

    Three machines, one Helm: the node (where roles/platform runs `helm
    upgrade`), the validate runner (which renders and unit-tests the charts)
    and the publish runner (which PACKAGES the app chart every app then pulls).
    A chart packaged by one version and rendered by another is a silent
    behaviour difference, which is the worst kind to debug from a rendered
    manifest.
    """
    problems = []
    wanted = block_scalar(read(GROUP_VARS), "helm_version", GROUP_VARS)
    for relpath in (VALIDATE_WF, PUBLISH_WF):
        for got in _setup_helm_versions(relpath):
            if got != wanted:
                problems.append(
                    f"{relpath}: azure/setup-helm installs {got}, but "
                    f"`helm_version` in {GROUP_VARS} is {wanted}.\n"
                    f"        FIX: set both to the same version. The node runs "
                    f"one Helm and CI must render with it."
                )
    return problems


def check_ansible_core_version():
    """The ansible-core pin in the linting workflow vs the deploying one.

    validate.yaml lints and syntax-checks the playbooks; deploy-platform.yaml
    APPLIES them. If those two interpreters differ, a green lint proves nothing
    about the run — and ansible-core minors do change module and templating
    behaviour.
    """
    problems = []
    pins = {}
    for relpath in (VALIDATE_WF, DEPLOY_WF):
        found = set(re.findall(r"ansible-core==([\w.]+)", read(relpath)))
        if not found:
            raise SyncError(
                f"{relpath}: no `ansible-core==<version>` pin found. An "
                f"unpinned install resolves to whatever is latest that day — "
                f"restore the pin or drop this check."
            )
        if len(found) > 1:
            problems.append(
                f"{relpath}: pins ansible-core to more than one version "
                f"({', '.join(sorted(found))})."
            )
        pins[relpath] = sorted(found)[0]
    if len(set(pins.values())) > 1:
        problems.append(
            "ansible-core is pinned differently per workflow: "
            + "; ".join(f"{path} == {version}" for path, version in sorted(pins.items()))
            + ".\n        FIX: make them identical. The thing that lints a "
            "playbook and the thing that applies it must be one interpreter."
        )
    return problems


def check_helm_unittest_version():
    """The helm-unittest plugin version in CI vs the one `make check` names.

    The plugin embeds its own rendering library, so the committed snapshots in
    charts/*/tests/__snapshot__ are reproducible only against the version that
    wrote them. A laptop installing a different one gets snapshot diffs that
    have nothing to do with the change under test.
    """
    problems = []
    validate = read(VALIDATE_WF)
    makefile = read(MAKEFILE)

    ci = re.search(r"HELM_UNITTEST_VERSION=(\S+)", validate)
    if not ci:
        raise SyncError(
            f"{VALIDATE_WF}: no `HELM_UNITTEST_VERSION=` assignment — the "
            f"install step was rewritten; update scripts/assert-sync.py."
        )
    # Bounded character class, not \S+: in the Makefile the version sits inside
    # a quoted `echo`, so \S+ would swallow the closing `";`.
    local = re.search(r"helm-unittest\s+--version\s+([\w.+-]+)", makefile)
    if not local:
        raise SyncError(
            f"{MAKEFILE}: the helm-unittest install hint no longer contains "
            f"`--version <version>`; update scripts/assert-sync.py."
        )
    if ci.group(1) != local.group(1):
        problems.append(
            f"helm-unittest is {ci.group(1)} in {VALIDATE_WF} but "
            f"{local.group(1)} in {MAKEFILE}.\n"
            f"        FIX: same version in both, or the committed chart "
            f"snapshots stop matching locally."
        )
    return problems


# Directories with no hand-written content to keep in sync.
_SKIP_DIRS = {".git", "node_modules", ".ansible", "__pycache__", ".venv"}


def _repo_files():
    for root, dirs, files in os.walk(REPO):
        dirs[:] = sorted(d for d in dirs if d not in _SKIP_DIRS)
        for name in sorted(files):
            path = os.path.join(root, name)
            yield os.path.relpath(path, REPO), path


def check_busybox_digest():
    """One busybox digest, repo-wide.

    busybox is the init container that chowns a hostPath volume before the
    real workload starts, wherever one exists. They are pinned by digest so the
    tag cannot be re-pointed under us, which only works if a bump touches every
    copy: a tree with two digests is a tree where one manifest was missed, and
    the one that was missed is exactly the one nobody rendered afterwards.
    """
    problems = []
    digests = {}
    pattern = re.compile(r"busybox(?::[\w.-]+)?@(sha256:[0-9a-f]{64})")
    for relpath, path in _repo_files():
        if os.path.splitext(relpath)[1] not in (
            ".yaml", ".yml", ".json", ".md", ".tpl", ".snap", ".sh", ".ts",
        ):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        for digest in pattern.findall(text):
            digests.setdefault(digest, set()).add(relpath)

    if not digests:
        raise SyncError(
            "no `busybox@sha256:` reference found anywhere in the repo. Every "
            "hostPath volume used to get chowned by one; if that is gone on "
            "purpose, drop this check."
        )
    if len(digests) > 1:
        detail = "\n".join(
            f"          {digest}  <- {', '.join(sorted(files))}"
            for digest, files in sorted(digests.items())
        )
        problems.append(
            f"{len(digests)} different busybox digests are in use:\n{detail}\n"
            f"        FIX: pin every copy to the same digest. A bump that "
            f"missed a file leaves one workload on an image nobody reviewed."
        )
    return problems


def check_private_hosts_smoked():
    """Every private hostname is actually probed by smoke.sh.

    group_vars' two private-hostname lists are the definition of "this name is
    served, tailnet-only". scripts/smoke.sh is the only thing that goes in the
    front door and finds out. A host in the config and not in the table is a
    surface nothing would notice the loss of — which is how a service stays
    down between two deploys.

    ONE-WAY on purpose: smoke.sh legitimately probes more than these lists
    (public hosts through the tunnel, plus app surfaces this repo does not
    declare), and the accepted status codes are a judgement call per service
    that no config file should try to express.
    """
    problems = []
    gv = read(GROUP_VARS)
    configured = set(block_list(gv, "private_hostnames", GROUP_VARS)) | set(
        block_list(gv, "private_hostnames_via_traefik", GROUP_VARS)
    )

    smoke = read(SMOKE)
    probed = set()
    for entry in bash_array(smoke, "PRIVATE_CHECKS", SMOKE):
        fields = entry.split("|")
        if len(fields) != 4:
            raise SyncError(
                f"{SMOKE}: PRIVATE_CHECKS entry {entry!r} has {len(fields)} "
                f"fields, expected 4 (method|url|codes|label)."
            )
        url = fields[1]
        host = url.split("://", 1)[-1].split("/", 1)[0]
        probed.add(host)

    missing = sorted(configured - probed)
    if missing:
        problems.append(
            f"private hostname(s) in {GROUP_VARS} with no probe in "
            f"PRIVATE_CHECKS ({SMOKE}): {', '.join(missing)}.\n"
            f"        FIX: add "
            f"`GET|https://<host>/|<codes>|<what it is>` for each. Pick the "
            f"codes from what the service actually serves an unauthenticated "
            f"caller (a redirect to a login page is a pass; 000/5xx never is)."
        )
    return problems


def _smoke_public_hosts():
    """Every hostname in smoke.sh's PUBLIC_CHECKS table."""
    hosts = set()
    for entry in bash_array(read(SMOKE), "PUBLIC_CHECKS", SMOKE):
        fields = entry.split("|")
        if len(fields) not in (4, 5):
            raise SyncError(
                f"{SMOKE}: PUBLIC_CHECKS entry {entry!r} has {len(fields)} "
                f"fields, expected 4 or 5 "
                f"(method|url|codes|label[|expected Location])."
            )
        hosts.add(fields[1].split("://", 1)[-1].split("/", 1)[0])
    return hosts


def check_public_hosts_have_repo():
    """Every public surface smoke.sh probes names the repo that deploys it.

    scripts/trigger-app-deploys.sh is what rebuilds the fleet after a repave.
    A repo missing from it is a service that silently never comes back — which
    is how jterrazz-web ended up absent while smoke.sh probed three of its
    hostnames. The hostname column in REPOS is only there to make that
    omission checkable; PLATFORM_PUBLIC_HOSTS covers the surfaces this repo
    deploys itself, so the check spans the whole table rather than a subset.
    """
    problems = []
    trigger = read(TRIGGER_DEPLOYS)

    claimed = {}
    for entry in bash_array(trigger, "REPOS", TRIGGER_DEPLOYS):
        fields = entry.split("|")
        if len(fields) != 2:
            raise SyncError(
                f"{TRIGGER_DEPLOYS}: REPOS entry {entry!r} has {len(fields)} "
                f"fields, expected 2 (owner/repo|space-separated hostnames)."
            )
        repo, hosts = fields
        if "/" not in repo:
            raise SyncError(
                f"{TRIGGER_DEPLOYS}: REPOS entry {entry!r} does not start with "
                f"an `owner/repo`."
            )
        for host in hosts.split():
            claimed[host] = repo
    for host in bash_array(trigger, "PLATFORM_PUBLIC_HOSTS", TRIGGER_DEPLOYS):
        claimed[host] = "this repo (roles/platform)"

    probed = _smoke_public_hosts()

    unclaimed = sorted(probed - set(claimed))
    unprobed = sorted(set(claimed) - probed)
    if unclaimed:
        problems.append(
            f"public hostname(s) in PUBLIC_CHECKS ({SMOKE}) that no entry in "
            f"{TRIGGER_DEPLOYS} claims: {', '.join(unclaimed)}.\n"
            f"        FIX: add the hostname to the owning repo's REPOS line "
            f"(adding the repo itself if it is missing — `make redeploy-apps` "
            f"is what brings it back after a repave), or to "
            f"PLATFORM_PUBLIC_HOSTS if this repo deploys it."
        )
    if unprobed:
        problems.append(
            f"hostname(s) named in {TRIGGER_DEPLOYS} that PUBLIC_CHECKS "
            f"({SMOKE}) does not probe: {', '.join(unprobed)}.\n"
            f"        FIX: add "
            f"`GET|https://<host>/|<codes>|<what it is>` to PUBLIC_CHECKS, or "
            f"drop the hostname here. An unprobed public surface is one whose "
            f"loss nobody notices."
        )
    return problems


def check_chart_publish_guard():
    """The two app-chart publish paths agree on the registry.

    The chart is pulled UNVERSIONED by every app, so both publishers — the
    script the workflow runs, and the Ansible task that covers the
    fresh-cluster case where the node has no checkout — must guard the same
    coordinates. The node cannot call the script (stage-manifests.yml copies
    only kubernetes/ to it), so the duplication is real; this is what keeps it
    honest.
    """
    problems = []
    script = read(PUBLISH_SCRIPT)
    workflow = read(PUBLISH_WF)

    if PUBLISH_SCRIPT not in workflow:
        problems.append(
            f"{PUBLISH_WF} does not run {PUBLISH_SCRIPT}.\n"
            f"        FIX: call the script. A second, hand-written copy of the "
            f"guard in the workflow is exactly what drifted before."
        )

    registry = re.search(r"^REGISTRY=(\S+)$", script, re.MULTILINE)
    if not registry:
        raise SyncError(
            f"{PUBLISH_SCRIPT}: no `REGISTRY=<host>` assignment — the script "
            f"was restructured; update scripts/assert-sync.py."
        )
    want_pull = f"oci://{registry.group(1)}/charts/app"
    want_push = f"oci://{registry.group(1)}/charts"

    if f'"oci://$REGISTRY/charts/app"' not in script or f'"oci://$REGISTRY/charts"' not in script:
        raise SyncError(
            f"{PUBLISH_SCRIPT}: expected a `helm pull oci://$REGISTRY/charts/"
            f"app` and a `helm push ... oci://$REGISTRY/charts`."
        )

    commands = ansible_commands(read(ANSIBLE_PUBLISH))
    pulls = [c for c in commands if "helm pull" in c]
    pushes = [c for c in commands if "helm push" in c]
    if len(pulls) != 1 or len(pushes) != 1:
        raise SyncError(
            f"{ANSIBLE_PUBLISH}: expected exactly one `helm pull` and one "
            f"`helm push`, found {len(pulls)} and {len(pushes)}."
        )
    # `.strip` because the inline `command: "helm push ... oci://…"` form keeps
    # its closing quote in the flattened token.
    def _oci(command):
        for token in command.split():
            if token.startswith("oci://"):
                return token.strip("\"'")
        return None

    got_pull = _oci(pulls[0])
    got_push = _oci(pushes[0])

    if got_pull != want_pull:
        problems.append(
            f"the already-published guard pulls {got_pull!r} in "
            f"{ANSIBLE_PUBLISH} but {want_pull!r} in {PUBLISH_SCRIPT}.\n"
            f"        FIX: one registry, one chart path. A guard pointed "
            f"somewhere else always says 'not published' and overwrites."
        )
    if got_push != want_push:
        problems.append(
            f"the push targets {got_push!r} in {ANSIBLE_PUBLISH} but "
            f"{want_push!r} in {PUBLISH_SCRIPT}.\n"
            f"        FIX: make them identical, or the two publishers fill two "
            f"different registries and apps pull whichever one they were "
            f"pointed at."
        )
    if "kubernetes/charts/app" not in " ".join(commands):
        problems.append(
            f"{ANSIBLE_PUBLISH} no longer packages kubernetes/charts/app.\n"
            f"        FIX: both publishers must package the same chart "
            f"directory."
        )
    return problems


CHECKS = [
    ("infisical-vars.py vars == preflight.yml asserts", check_secret_keys),
    ("traefik trustedIPs == rate-limit excludedIPs", check_traefik_trusted_ips),
    ("platform_chart_versions pins are all consumed", check_chart_version_pins),
    ("platform-diff.sh release table == ansible helm installs", check_platform_diff_table),
    ("helm_version == the Helm both workflows install", check_helm_version),
    ("ansible-core pinned identically in validate + deploy", check_ansible_core_version),
    ("helm-unittest pinned identically in validate + Makefile", check_helm_unittest_version),
    ("one busybox digest repo-wide", check_busybox_digest),
    ("private hostnames are all probed by smoke.sh", check_private_hosts_smoked),
    ("public hostnames all name a deploying repo", check_public_hosts_have_repo),
    ("both app-chart publish guards agree", check_chart_publish_guard),
]


def main():
    # GitHub renders `::error::` as an annotation on the failing step; a plain
    # line is fine everywhere else. (Same convention as infisical-vars.py.)
    annotate = bool(os.environ.get("GITHUB_ACTIONS"))
    failed = 0

    for title, check in CHECKS:
        try:
            problems = check()
        except SyncError as exc:
            problems = [f"CANNOT CHECK — {exc}"]
        if problems:
            failed += 1
            print(f"FAIL  {title}")
            for problem in problems:
                prefix = "::error::" if annotate else ""
                print(f"      {prefix}{problem}")
        else:
            print(f"PASS  {title}")

    if failed:
        print(
            f"\n{failed} of {len(CHECKS)} sync assertions failed. Each pair "
            f"above is one fact written in two files on purpose (two different "
            f"consumers); the comment saying 'keep in sync' is not a check — "
            f"this script is.",
            file=sys.stderr,
        )
        return 1
    print(f"\nAll {len(CHECKS)} sync assertions hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
