"""Build one downloadable `.personal` file per persona folder.

A `.personal` file is the same UTF-8 JSON the app writes on export:
{"files": {path: text}, "manifest": {...}} — see docs/persona-file-format.md.

Usage: python3 scripts/build_personals.py   (writes dist/personals/<id>.personal)
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "Galchat" / "Personas"
OUTPUT = ROOT / "dist" / "personals"
EXTENSION = ".personal"


def load(directory: Path) -> dict:
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    paths = manifest["documents"] + manifest.get("licenseFiles", [])
    files = {path: (directory / path).read_text(encoding="utf-8") for path in paths}
    return {"manifest": manifest, "files": files}


def encode(package: dict) -> bytes:
    # 与 Swift JSONEncoder([.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) 的结构一致。
    return (json.dumps(package, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def packages() -> list[tuple[str, bytes]]:
    result = []
    for directory in sorted(PACKAGES.iterdir()):
        if directory.is_dir():
            package = load(directory)
            result.append((package["manifest"]["id"], encode(package)))
    return result


def build() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    built = packages()
    wanted = {f"{ident}{EXTENSION}" for ident, _ in built}
    for stale in OUTPUT.glob(f"*{EXTENSION}"):
        if stale.name not in wanted:
            stale.unlink()
    for ident, data in built:
        (OUTPUT / f"{ident}{EXTENSION}").write_bytes(data)
        print(f"{ident}{EXTENSION}: {len(data)} bytes")


if __name__ == "__main__":
    build()
