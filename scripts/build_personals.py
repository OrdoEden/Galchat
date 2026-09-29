"""Build the publishable resource library (personas + prompt pack).

Output (dist/personals/, push its contents to the root of github.com/OrdoEden/GalchatResource):
  <id>.personal          UTF-8 JSON {"assets": {path: base64}, "files": {path: text}, "manifest": {...}}
  portraits/<id>.<ext>   the portrait, for list thumbnails
  prompts/prompts.json   all model prompts: reply, sticker, Jev wording and scoring criteria (Galchat/Prompts/prompts.json)
  catalog.json           what the app downloads: personas and the prompt pack with sha256/size, plus revoked ids

Takedowns: add {"id": "...", "reason": "..."} to catalog/revoked.json and rebuild. Revoked personas are
left out of the catalog, and the app deletes installed copies the next time it syncs.

Usage: python3 scripts/build_personals.py
"""
import base64
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "Galchat" / "Personas"
OUTPUT = ROOT / "dist" / "personals"
REVOKED = ROOT / "catalog" / "revoked.json"
PROMPTS = ROOT / "Galchat" / "Prompts" / "prompts.json"
PROMPTS_PATH = "prompts/prompts.json"
EXTENSION = ".personal"


def load(directory: Path) -> dict:
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    paths = manifest["documents"] + manifest.get("licenseFiles", [])
    files = {path: (directory / path).read_text(encoding="utf-8") for path in paths}
    package = {"manifest": manifest, "files": files}
    if "portrait" in manifest:
        data = (directory / manifest["portrait"]).read_bytes()
        package["assets"] = {manifest["portrait"]: base64.b64encode(data).decode("ascii")}
    return package


def encode(value: dict) -> bytes:
    # 与 Swift JSONEncoder([.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) 的结构一致。
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def revoked() -> list[dict]:
    return json.loads(REVOKED.read_text(encoding="utf-8"))["revoked"]


def outputs() -> dict[str, bytes]:
    """Every published file, keyed by path relative to OUTPUT."""
    revoked_ids = {entry["id"].casefold() for entry in revoked()}
    files: dict[str, bytes] = {}
    personas = []
    for directory in sorted(PACKAGES.iterdir()):
        if not directory.is_dir():
            continue
        package = load(directory)
        manifest = package["manifest"]
        ident = manifest["id"]
        if ident.casefold() in revoked_ids:
            continue
        data = encode(package)
        files[f"{ident}{EXTENSION}"] = data
        entry = {
            "id": ident,
            "name": manifest["name"],
            "summary": manifest["summary"],
            "version": manifest["version"],
            "package": f"{ident}{EXTENSION}",
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
            "sortOrder": manifest.get("sortOrder", 1000),
        }
        if "portrait" in manifest:
            path = f"portraits/{ident}{Path(manifest['portrait']).suffix.lower()}"
            files[path] = (directory / manifest["portrait"]).read_bytes()
            entry["portrait"] = path
        personas.append(entry)
    prompts = PROMPTS.read_bytes()
    files[PROMPTS_PATH] = prompts
    prompts_entry = {"version": json.loads(prompts)["version"], "package": PROMPTS_PATH,
                     "sha256": hashlib.sha256(prompts).hexdigest(), "size": len(prompts)}
    files["catalog.json"] = encode({"schemaVersion": 1, "personas": personas, "revoked": revoked(), "prompts": prompts_entry})
    return files


def packages() -> list[tuple[str, bytes]]:
    return [(path[: -len(EXTENSION)], data) for path, data in outputs().items() if path.endswith(EXTENSION)]


def build() -> None:
    wanted = outputs()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for stale in [*OUTPUT.glob(f"*{EXTENSION}"), *OUTPUT.glob("portraits/*"), *OUTPUT.glob("prompts/*")]:
        if str(stale.relative_to(OUTPUT)) not in wanted:
            stale.unlink()
    for path, data in wanted.items():
        target = OUTPUT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"{path}: {len(data)} bytes")


if __name__ == "__main__":
    build()
