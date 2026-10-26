# invariant: run inside Grafana's alerts sidecar (python, the admin pair in REQ_USERNAME and
# REQ_PASSWORD, Grafana on localhost). Deletes a folder only when another folder holds its title
# and it holds no dashboard and no alert rule; prints one line per deletion.
# outside: the dashboard sidecar and the alert sidecar each create a missing folder by title; on a
# fresh database they race and both win, leaving an empty twin (2026-10-26 repave).
import base64
import json
import os
import urllib.request
from collections import defaultdict

AUTH = base64.b64encode(f"{os.environ['REQ_USERNAME']}:{os.environ['REQ_PASSWORD']}".encode()).decode()


def call(method, path):
    request = urllib.request.Request(
        "http://localhost:3000" + path, method=method, headers={"Authorization": "Basic " + AUTH}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"null")


folders = call("GET", "/api/folders?limit=1000")
ruled = {rule["folderUID"] for rule in call("GET", "/api/v1/provisioning/alert-rules")}
by_title = defaultdict(list)
for folder in folders:
    by_title[folder["title"]].append(folder["uid"])

for title, uids in by_title.items():
    if len(uids) < 2:
        continue
    empty = [uid for uid in uids if uid not in ruled and not call("GET", f"/api/search?folderUIDs={uid}")]
    # invariant: one folder of the title always stays, even when every twin is empty.
    for uid in empty[: len(empty) - (len(empty) == len(uids))]:
        call("DELETE", f"/api/folders/{uid}")
        print(f"deleted empty twin {title} ({uid})")
