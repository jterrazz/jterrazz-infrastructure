# invariant: run inside Grafana's alerts sidecar (python, the admin pair in REQ_USERNAME and
# REQ_PASSWORD, Grafana on localhost). Deletes every folder that holds no dashboard and no alert
# rule; prints one line per deletion.
# outside: a sidecar creates a missing folder by title and nothing ever removes one. On a fresh
# database the dashboard and alert sidecars race into twin folders of one title (2026-10-26
# repave), and a renamed owner or a removed app leaves its folder behind (ADR-027).
import base64
import json
import os
import urllib.request

AUTH = base64.b64encode(f"{os.environ['REQ_USERNAME']}:{os.environ['REQ_PASSWORD']}".encode()).decode()


def call(method, path):
    request = urllib.request.Request(
        "http://localhost:3000" + path, method=method, headers={"Authorization": "Basic " + AUTH}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"null")


ruled = {rule["folderUID"] for rule in call("GET", "/api/v1/provisioning/alert-rules")}
for folder in call("GET", "/api/folders?limit=1000"):
    if folder["uid"] in ruled or call("GET", f"/api/search?folderUIDs={folder['uid']}"):
        continue
    call("DELETE", f"/api/folders/{folder['uid']}")
    print(f"deleted empty folder {folder['title']} ({folder['uid']})")
