"""Validate shipped persona assets and resource wiring without building iOS."""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "Galchat" / "Personas"


def check():
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-",
        str(ROOT / "Galchat.xcodeproj" / "project.pbxproj"),
    ]))
    groups = [obj for obj in project["objects"].values()
              if obj.get("isa") == "PBXFileSystemSynchronizedRootGroup"
              and obj.get("path") == "Galchat"]
    assert len(groups) == 1 and "Personas" in groups[0].get("explicitFolders", []), "Resource folder must preserve paths"

    ids = set()
    defaults = 0
    for directory in sorted(PACKAGES.iterdir()):
        if not directory.is_dir():
            continue
        manifest = json.loads((directory / "manifest.json").read_text())
        ident = manifest["id"]
        assert manifest["schemaVersion"] == 1
        assert re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", ident) and ident not in (".", "..")
        assert ident.casefold() not in ids, f"Duplicate ID: {ident}"
        ids.add(ident.casefold())
        assert 0 < len(manifest["name"].strip()) <= 50
        assert len(manifest["summary"]) <= 500 and 0 < len(manifest["version"]) <= 100
        defaults += manifest.get("defaultSelected", False)
        documents = manifest["documents"]
        paths = documents + manifest.get("licenseFiles", [])
        assert documents and len(paths) <= 64 and len(set(paths)) == len(paths)
        assert all(path.lower().endswith(".md") for path in documents)
        files = {}
        for path in paths:
            assert len(path.encode()) <= 240 and "\\" not in path
            assert all(part not in ("", ".", "..") for part in path.split("/"))
            assert not any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in path)
            candidate = directory
            for part in path.split("/"):
                candidate = candidate / part
                assert not candidate.is_symlink(), f"Symlink: {candidate}"
            assert candidate.resolve().is_relative_to(directory.resolve())
            files[path] = candidate.read_text(encoding="utf-8")
            assert files[path].strip(), f"Empty file: {candidate}"
        # An undeclared document would be silently omitted from the actual prompt.
        assert {str(p.relative_to(directory)) for p in directory.rglob("*.md")} == set(documents)
        payload = {"manifest": manifest, "files": files}
        encoded = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).encode()
        assert len(encoded) <= 1_000_000
        assert json.loads(encoded) == payload
        prompt = "\n\n".join([f"人格：{manifest['name']}", manifest["summary"]]
                              + [f"【{path}】\n{files[path]}" for path in documents])
        assert len(prompt.encode()) <= 128_000
        print(f"{ident}: {len(documents)} complete documents, {len(prompt.encode())} prompt bytes")
    assert ids and defaults == 1
    print("Persona asset checks passed (no Swift compilation or app execution).")


if __name__ == "__main__":
    check()
