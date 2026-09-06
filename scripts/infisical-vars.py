#!/usr/bin/env python3
"""Fetch the Ansible-bound secrets from Infisical into an extra-vars YAML file.

THE single implementation, shared by scripts/deploy.sh (laptop) and
.github/workflows/deploy-platform.yaml (CI) — do not fork it back into either.

Usage:
    infisical-vars.py <site|platform> <output-path>

    site      — everything site.yml needs, including the Tailscale OAuth
                credentials the tailscale role logs in with.
    platform  — everything platform.yml needs. No Tailscale OAuth: the
                platform play only reads Tailscale *facts* off an
                already-joined node (roles/tailscale/tasks/facts.yml).

Environment:
    INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET — universal-auth machine
    identity. These are ALSO written into the output file: the Infisical
    operator running in-cluster needs them, and they can't come from
    Infisical itself (chicken-and-egg).

Each secret path is fetched EXPLICITLY (not recursively) so short keys can
repeat across services without colliding. Any missing key is a hard failure:
silently dropping one lets an Ansible role default paper over a real Infisical
misconfiguration.

KEEP SCOPES IN SYNC with the assert list in
ansible/roles/platform/tasks/preflight.yml. That task is the second gate on
this same set: a var fetched here but unasserted there fails halfway through a
deploy instead of before it starts.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://eu.infisical.com"
WORKSPACE = "jterrazz"
ENVIRONMENT = "prod"

ROOT_PATH = "/jterrazz-infrastructure"
GRAFANA_PATH = "/jterrazz-infrastructure/grafana"

# ansible variable -> (infisical secret path, key at that path)
COMMON_VARS = {
    "cloudflare_api_token": (ROOT_PATH, "CLOUDFLARE_API_TOKEN"),
    "cloudflare_tunnel_token": (ROOT_PATH, "CLOUDFLARE_TUNNEL_TOKEN"),
    # The registry ACCOUNT, both halves. The name is fetched rather than
    # hardcoded because a password rotation overlaps two accounts
    # (`deploy` / `deploy-next`) and the htpasswd line Ansible generates has to
    # follow the one CI and the kubelet authenticate with — see § Rotating the
    # registry password in docs/09-runbook.md.
    "registry_username": (ROOT_PATH, "DOCKER_REGISTRY_USERNAME"),
    "registry_password": (ROOT_PATH, "DOCKER_REGISTRY_PASSWORD"),
    "grafana_admin_password": (GRAFANA_PATH, "ADMIN_PASSWORD"),
}

SITE_ONLY_VARS = {
    "tailscale_oauth_client_id": (ROOT_PATH, "TAILSCALE_OAUTH_CLIENT_ID"),
    "tailscale_oauth_client_secret": (ROOT_PATH, "TAILSCALE_OAUTH_CLIENT_SECRET"),
}

SCOPES = {
    "site": {**COMMON_VARS, **SITE_ONLY_VARS},
    "platform": COMMON_VARS,
}


def die(message):
    # GitHub renders `::error::` as an annotation on the failing step.
    prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else "ERROR: "
    print(f"{prefix}{message}", file=sys.stderr)
    sys.exit(1)


# eu.infisical.com sits behind Cloudflare, whose bot protection 403s the
# default "Python-urllib/3.x" User-Agent while letting curl through — every
# request must carry an explicit UA or login fails with a misleading 403.
USER_AGENT = "jterrazz-infrastructure-deploy/1.0"


def post_json(url, payload):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def login(client_id, client_secret):
    try:
        return post_json(
            f"{API}/api/v1/auth/universal-auth/login",
            {"clientId": client_id, "clientSecret": client_secret},
        )["accessToken"]
    except (urllib.error.URLError, KeyError, ValueError) as exc:
        die(f"Infisical universal-auth login failed: {exc}")


def fetch_path(token, secret_path):
    query = urllib.parse.urlencode(
        {
            "workspaceSlug": WORKSPACE,
            "environment": ENVIRONMENT,
            "secretPath": secret_path,
        }
    )
    request = urllib.request.Request(
        f"{API}/api/v3/secrets/raw?{query}",
        headers={"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except (urllib.error.URLError, ValueError) as exc:
        die(f"Infisical fetch of {secret_path} failed: {exc}")
    return {s["secretKey"]: s["secretValue"] for s in body.get("secrets", [])}


def yaml_escape(value):
    # Callers quote everything: a token may start with `[` or contain `:`,
    # both meaningful to the YAML parser. Newlines are escaped too, so a
    # multi-line secret cannot break the file.
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in SCOPES:
        die(f"usage: {sys.argv[0]} <{'|'.join(SCOPES)}> <output-path>")

    scope, outpath = sys.argv[1], sys.argv[2]
    wanted = SCOPES[scope]

    client_id = os.environ.get("INFISICAL_CLIENT_ID")
    client_secret = os.environ.get("INFISICAL_CLIENT_SECRET")
    if not client_id or not client_secret:
        die("INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET must be set")

    token = login(client_id, client_secret)

    cache = {}
    for path, _ in set(wanted.values()):
        if path not in cache:
            cache[path] = fetch_path(token, path)

    out = {var: cache[path].get(key) for var, (path, key) in wanted.items()}

    missing = sorted(var for var, value in out.items() if value is None)
    if missing:
        die(f"Missing Infisical secrets: {', '.join(missing)}")

    out["infisical_client_id"] = client_id
    out["infisical_client_secret"] = client_secret

    # os.open with 0600, not open(): the file never has a world-readable
    # window, even if the caller forgot to mktemp it.
    fd = os.open(outpath, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        for var, value in out.items():
            handle.write(f'{var}: "{yaml_escape(value)}"\n')


if __name__ == "__main__":
    main()
