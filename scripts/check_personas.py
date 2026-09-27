"""Validate shipped persona assets, the `.personal` builds and resource wiring without building iOS."""
import json
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_personals  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "Galchat" / "Personas"

# 人格原型的来源作品、真实人物、平台/社群与粗口。以转义形式保存，仓库里不出现这些原文。
# 发现任何一个即失败：人格只能写抽象后的特点，不写来源名称。
BANNED = [
    "\u7504\u5b1b", "\u534e\u5983", "\u83ef\u5983", "\u6d41\u6731", "\u6d63\u78a7", "\u69ff\u6c50",
    "\u82cf\u57f9\u76db", "\u8607\u57f9\u76db", "\u6e29\u5b9e\u521d", "\u6eab\u5be6\u521d", "\u679c\u90e1\u738b",
    "\u5b89\u9675\u5bb9", "\u6c88\u7709\u5e84", "\u6c88\u7709\u838a", "\u7eaf\u5143", "\u7d14\u5143",
    "\u788e\u7389\u8f69", "\u788e\u7389\u8ed2", "\u839e\u839e\u7c7b\u537f", "\u9519\u4ed8", "\u932f\u4ed8",
    "\u672c\u5bab\u4e4f\u4e86", "\u5154\u5a18", "\u718a\u8389", "\u83c7\u51c9", "\u8700\u9053\u5c71",
    "\u8d34\u5427", "\u8cbc\u5427", "\u5b59\u7b11\u5ddd", "\u5409\u5409\u56fd", "\u7535\u68cd", "\u70ab\u72d7",
    "\u70ab\u795e", "\u5c71\u6ce5\u82e5", "\u8c46\u5305", "\u5b57\u8282\u8df3\u52a8", "\u7ae5\u9526\u7a0b",
    "\u9526\u7a0b", "\u666f\u8fb0", "\u82e5\u79bb", "\u8f9b\u5df4", "\u8f9b\u9009", "\u8f9b\u6709\u5fd7",
    "\u5feb\u624b", "\u6296\u97f3", "\u6df1\u60c5\u7956\u5e08\u7237", "\u007a\u0068\u0065\u006e\u0068\u0075\u0061\u006e", "\u0074\u0075\u006e\u0069\u0061\u006e\u0067", "\u0074\u0069\u0065\u0062\u0061",
    "\u0064\u006f\u0075\u0062\u0061\u006f", "\u0062\u0079\u0074\u0065\u0064\u0061\u006e\u0063\u0065", "\u0074\u006f\u006e\u0067\u002d\u006a\u0069\u006e\u0063\u0068\u0065\u006e\u0067", "\u006a\u0069\u006e\u0063\u0068\u0065\u006e\u0067", "\u0079\u006c\u0067", "\u006e\u006d\u0073\u006c", "\u64cd\u4f60", "\u50bb\u903c",
    "\u4f60\u5988",
    "\u8fea\u8fe6", "\u5965\u7279\u66fc", "\u5967\u7279\u66fc", "\u5706\u8c37", "\u5713\u8c37", "\u5927\u53e4", "\u80dc\u5229\u961f", "\u5149\u4e4b\u5de8\u4eba", "\u0074\u0069\u0067\u0061", "\u0075\u006c\u0074\u0072\u0061\u006d\u0061\u006e", "\u0074\u0073\u0075\u0062\u0075\u0072\u0061\u0079\u0061",
]


def scan(label: str, text: str) -> None:
    lowered = text.casefold()
    hits = [term for term in BANNED if term.casefold() in lowered]
    assert not hits, f"Sensitive term in {label}: {[t.encode('unicode_escape').decode() for t in hits]}"


def apply_transform(transform: dict, text: str) -> str:
    """Python mirror of PersonaPackage.ReplyTransform.apply for replaceText."""
    return "".join(transform["replacement"] if ch.isalpha() or ch.isnumeric() else ch for ch in text)


def check_transform(ident: str, transform: dict) -> None:
    assert set(transform) == {"kind", "replacement"}, f"{ident}: unknown replyTransform keys"
    assert transform["kind"] == "replaceText", f"{ident}: unsupported replyTransform kind"
    replacement = transform["replacement"]
    assert len(replacement) == 1 and not replacement.isspace(), f"{ident}: replacement must be one character"
    sample = apply_transform(transform, "确实 是这样的！OK 2 次😊")
    assert sample == "".join(replacement if c not in " ！😊" else c for c in "确实 是这样的！OK 2 次😊"), sample


def check():
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-",
        str(ROOT / "Galchat.xcodeproj" / "project.pbxproj"),
    ]))
    groups = [obj for obj in project["objects"].values()
              if obj.get("isa") == "PBXFileSystemSynchronizedRootGroup"
              and obj.get("path") == "Galchat"]
    assert len(groups) == 1 and "Personas" in groups[0].get("explicitFolders", []), "Resource folder must preserve paths"

    info = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "Galchat" / "Info.plist"),
    ]))
    exported = [t for t in info.get("UTExportedTypeDeclarations", [])
                if t.get("UTTypeIdentifier") == "com.heself.galchat.personal"]
    assert len(exported) == 1, "Info.plist must export the .personal type"
    assert exported[0]["UTTypeTagSpecification"]["public.filename-extension"] == ["personal"]
    assert any("com.heself.galchat.personal" in d.get("LSItemContentTypes", [])
               for d in info.get("CFBundleDocumentTypes", [])), "Info.plist must open .personal files"

    ids = set()
    defaults = 0
    for directory in sorted(PACKAGES.iterdir()):
        if not directory.is_dir():
            continue
        manifest = json.loads((directory / "manifest.json").read_text())
        ident = manifest["id"]
        assert manifest["schemaVersion"] == 1
        assert re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", ident) and ident not in (".", "..")
        assert ident == directory.name, f"Folder name must equal ID: {directory.name}"
        assert ident.casefold() not in ids, f"Duplicate ID: {ident}"
        ids.add(ident.casefold())
        assert 0 < len(manifest["name"].strip()) <= 50
        assert len(manifest["summary"]) <= 500 and 0 < len(manifest["version"]) <= 100
        defaults += manifest.get("defaultSelected", False)
        if "replyTransform" in manifest:
            check_transform(ident, manifest["replyTransform"])
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
        # LICENSE 是上游 MIT 原文，只检查会进入人格上下文或展示给用户的内容。
        scan(f"{ident}/manifest.json", json.dumps(manifest, ensure_ascii=False))
        for path in paths:
            if path != "LICENSE":
                scan(f"{ident}/{path}", files[path])
        payload = {"manifest": manifest, "files": files}
        encoded = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).encode()
        assert len(encoded) <= 1_000_000
        assert json.loads(encoded) == payload
        prompt = "\n\n".join([f"人格：{manifest['name']}", manifest["summary"]]
                              + [f"【{path}】\n{files[path]}" for path in documents])
        assert len(prompt.encode()) <= 128_000
        print(f"{ident}: {len(documents)} documents, {len(prompt.encode())} prompt bytes")
    assert ids and defaults == 1

    # 可下载的 .personal 必须与文件夹内容一致，避免分发旧版本。
    built = dict(build_personals.packages())
    on_disk = {p.stem: p.read_bytes() for p in build_personals.OUTPUT.glob(f"*{build_personals.EXTENSION}")}
    assert on_disk == built, "dist/personals is stale; run python3 scripts/build_personals.py"
    scan("README.md", (ROOT / "README.md").read_text(encoding="utf-8"))
    print(f"{len(built)} .personal files up to date; no sensitive terms found.")
    print("Persona asset checks passed (no Swift compilation or app execution).")


if __name__ == "__main__":
    check()
