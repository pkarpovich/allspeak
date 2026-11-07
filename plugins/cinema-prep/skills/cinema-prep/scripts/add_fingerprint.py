# /// script
# dependencies = ["requests"]
# ///
import hashlib, json, os, sys
import requests

api = os.environ["CATALOG_API"].rstrip("/")
admin = {"Authorization": "Bearer " + os.environ["AUTH_ADMIN_TOKEN"]}
read = {"Authorization": "Bearer " + os.environ["AUTH_READ_TOKEN"]}
session_id, catalog_path = sys.argv[1], sys.argv[2]

def ref(f):
    return {"filename": f["filename"], "size": f["size"], "sha256": f["sha256"]}

detail = requests.get(f"{api}/sessions/{session_id}", headers=read, timeout=30).json()
manifest = {
    "tracks": [{**ref(t), "label": t["label"], "sortOrder": t["sortOrder"], "isDefault": t["isDefault"]} for t in detail["tracks"]],
    "subtitle": ref(detail["subtitle"]),
}
if detail.get("clip"):
    manifest["clip"] = ref(detail["clip"])
data = open(catalog_path, "rb").read()
fp = {"filename": os.path.basename(catalog_path), "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
manifest["fingerprint"] = fp
files = [ref(t) for t in manifest["tracks"]] + [manifest["subtitle"]] + ([manifest["clip"]] if "clip" in manifest else []) + [fp]
up = requests.post(f"{api}/uploads", headers=admin, json={"sessionId": session_id, "files": files}, timeout=60)
up.raise_for_status()
for f in up.json()["files"]:
    if f.get("exists"):
        continue
    assert f["sha256"] == fp["sha256"], f"unexpected upload request for {f['filename']}"
    r = requests.put(f["uploadUrl"], data=data, timeout=300)
    r.raise_for_status()
fin = requests.put(f"{api}/sessions/{session_id}", headers=admin, json={"title": detail["title"], "manifest": manifest}, timeout=60)
fin.raise_for_status()
after = requests.get(f"{api}/sessions/{session_id}", headers=read, timeout=30).json()
before_shas = sorted([t["sha256"] for t in detail["tracks"]] + [detail["subtitle"]["sha256"]] + ([detail["clip"]["sha256"]] if detail.get("clip") else []))
after_shas = sorted([t["sha256"] for t in after["tracks"]] + [after["subtitle"]["sha256"]] + ([after["clip"]["sha256"]] if after.get("clip") else []))
print(json.dumps({
    "title": after["title"],
    "revision": f"{detail['revision']} -> {after['revision']}",
    "existing files unchanged": before_shas == after_shas,
    "fingerprint": {k: after.get("fingerprint", {}).get(k) for k in ("filename", "size")},
}, ensure_ascii=False))
