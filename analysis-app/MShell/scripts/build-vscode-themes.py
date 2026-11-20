#!/usr/bin/env python3
"""Add selected Visual Studio Code color themes to the bundled theme blueprint.

The existing assets in vscode-themes.json are kept unchanged. Each selected theme is read from a
locally installed Visual Studio Code app (built-in theme extensions) or from a downloaded .vsix
package, its `include` chain is resolved, and only valid hex workbench colors are kept. Token colors
are not used. The script writes vscode-themes.json, vscode-themes.sha256 and the third-party license
notice next to them.

Usage:
  python3 -I scripts/build-vscode-themes.py --vscode-app "/Applications/Visual Studio Code.app" \
      --vsix-dir /path/to/packages

`--vsix-dir` holds one `<publisher>.<name>-<version>.vsix` file per extension, in any subfolder.
Packages are read as zip data only; nothing in them is executed.
"""
import argparse
import hashlib
import json
import os
import posixpath
import re
import zipfile

RESOURCES = os.path.join(os.path.dirname(__file__), "..", "Sources", "app", "Resources")
MAX_ASSETS = 64

# Visual Studio Code built-in theme extensions (MIT, same license as theme-defaults).
BUILTIN = {
    "theme-abyss": ["Abyss"],
    "theme-kimbie-dark": ["Kimbie Dark"],
    "theme-monokai": ["Monokai"],
    "theme-monokai-dimmed": ["Monokai Dimmed"],
    "theme-quietlight": ["Quiet Light"],
    "theme-red": ["Red"],
    "theme-solarized-dark": ["Solarized Dark"],
    "theme-solarized-light": ["Solarized Light"],
    "theme-tomorrow-night-blue": ["Tomorrow Night Blue"],
}

# Most installed Marketplace themes (November 20, 2026), MIT licensed. Variants that differ only in
# font style (italics) or borders are skipped because they share workbench colors.
COMMUNITY = {
    "GitHub.github-vscode-theme": ["GitHub Dark Default", "GitHub Dark Dimmed", "GitHub Light Default",
                                   "GitHub Dark High Contrast", "GitHub Light High Contrast"],
    "zhuangtongfa.Material-theme": ["One Dark Pro", "One Dark Pro Darker"],
    "dracula-theme.theme-dracula": ["Dracula Theme", "Dracula Theme Soft"],
    "akamud.vscode-theme-onedark": ["Atom One Dark"],
    "akamud.vscode-theme-onelight": ["Atom One Light"],
    "teabyii.ayu": ["Ayu Dark", "Ayu Mirage", "Ayu Light"],
    "johnpapa.winteriscoming": ["Winter is Coming (Dark Blue)", "Winter is Coming (Dark Black)", "Winter is Coming (Light)"],
    "sdras.night-owl": ["Night Owl", "Night Owl Light"],
    "enkia.tokyo-night": ["Tokyo Night", "Tokyo Night Storm", "Tokyo Night Light"],
    "azemoh.one-monokai": ["One Monokai"],
    "whizkydee.material-palenight-theme": ["Palenight Theme"],
    "RobbOwen.synthwave-vscode": ["SynthWave '84"],
    "ahmadawais.shades-of-purple": ["Shades of Purple"],
    "wesbos.theme-cobalt2": ["Cobalt2"],
    "EliverLara.andromeda": ["Andromeda"],
    "Catppuccin.catppuccin-vsc": ["Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappé", "Catppuccin Latte"],
    "liviuschera.noctis": ["Noctis", "Noctis Obscuro", "Noctis Lux"],
    "arcticicestudio.nord-visual-studio-code": ["Nord"],
    "jdinhlife.gruvbox": ["Gruvbox Dark Medium", "Gruvbox Dark Hard", "Gruvbox Light Medium"],
}

APPEARANCE = {"vs": "light", "vs-dark": "dark", "hc-black": "high-contrast-dark", "hc-light": "high-contrast-light"}
HEX = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")


def strip_jsonc(text):
    """Remove comments and trailing commas outside strings."""
    out, i, n, in_string = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True; out.append(c); i += 1
        elif text.startswith("//", i):
            while i < n and text[i] not in "\r\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c); i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def load_json(data):
    return json.loads(strip_jsonc(data.decode("utf-8-sig")))


class Source:
    """A theme extension read from a directory or a .vsix zip."""

    def __init__(self, label, read, root):
        self.label, self._read, self.root, self.files = label, read, root, {}

    def read(self, path):
        data = self._read(path)
        self.files[path] = data
        return data


def directory_source(label, path):
    def read(rel):
        full = os.path.realpath(os.path.join(path, rel))
        if not full.startswith(os.path.realpath(path) + os.sep):
            raise ValueError(f"path escapes extension: {rel}")
        with open(full, "rb") as handle:
            return handle.read()
    return Source(label, read, "")


def vsix_source(label, path):
    archive = zipfile.ZipFile(path)
    names = set(archive.namelist())

    def read(rel):
        name = posixpath.normpath(posixpath.join("extension", rel))
        if not name.startswith("extension/") or name not in names:
            raise ValueError(f"missing or invalid package path: {rel}")
        return archive.read(name)
    return Source(label, read, "extension/")


def resolve_colors(source, path, depth=0):
    if depth > 8:
        raise ValueError(f"include chain too deep at {path}")
    theme = load_json(source.read(path))
    colors, evidence = {}, {}
    if isinstance(theme.get("include"), str):
        parent = posixpath.normpath(posixpath.join(posixpath.dirname(path), theme["include"]))
        colors, evidence = resolve_colors(source, parent, depth + 1)
    for key, value in (theme.get("colors") or {}).items():
        if isinstance(value, str) and HEX.match(value):
            colors[key] = value
            evidence[key] = {"source": f"{source.label}/{source.root}{path}", "pointer": "/colors/" + key.replace("~", "~0").replace("/", "~1")}
        elif key in colors and value is None:
            del colors[key], evidence[key]
    return colors, evidence


def theme_assets(source, wanted, licenses):
    package = load_json(source.read("package.json"))
    nls = {}
    try:
        nls = load_json(source.read("package.nls.json"))
    except (ValueError, KeyError, FileNotFoundError):
        pass
    contributed = package.get("contributes", {}).get("themes", [])
    labels = {}
    for index, entry in enumerate(contributed):
        label = entry.get("label") or entry.get("id")
        if isinstance(label, str) and label.startswith("%") and label.endswith("%"):
            label = nls.get(label[1:-1], label)
        labels[label] = (index, entry)
    assets = []
    for name in wanted:
        if name not in labels:
            raise SystemExit(f"{source.label}: theme not found: {name}")
        index, entry = labels[name]
        appearance = APPEARANCE.get(entry.get("uiTheme"))
        if appearance is None:
            raise SystemExit(f"{source.label}: unsupported uiTheme for {name}")
        path = posixpath.normpath(entry["path"])
        colors, evidence = resolve_colors(source, path)
        if not colors.get("editor.background"):
            raise SystemExit(f"{source.label}: {name} has no editor.background")
        assets.append({
            "id": name, "kind": "color-palette", "label": name, "appearance": appearance,
            "colors": {key: {"value": colors[key], "evidence": evidence[key]} for key in sorted(colors)},
            "evidence": [{"source": f"{source.label}/{source.root}package.json", "pointer": f"/contributes/themes/{index}"}],
        })
    licenses.append((source.label, package.get("publisher"), package.get("version"), package.get("license")))
    return assets


def license_text(source):
    for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "license", "license.md", "License.md", "LICENCE"):
        try:
            return source.read(name).decode("utf-8", "replace").strip()
        except (ValueError, KeyError, FileNotFoundError, IsADirectoryError):
            continue
    raise SystemExit(f"{source.label}: no license file")


def find_vsix(directory, extension_id):
    pattern = re.compile(re.escape(extension_id) + r"-([0-9][^/]*)\.vsix$")
    for root, _, files in os.walk(directory):
        for name in files:
            match = pattern.match(name)
            if match:
                return os.path.join(root, name), match.group(1)
    raise SystemExit(f"package not found for {extension_id}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vscode-app", required=True)
    parser.add_argument("--vsix-dir", required=True)
    args = parser.parse_args()

    blueprint_path = os.path.join(RESOURCES, "vscode-themes.json")
    with open(blueprint_path, encoding="utf-8") as handle:
        blueprint = json.load(handle)
    original = [a for a in blueprint["assets"] if a["evidence"][0]["source"].startswith("extensions/theme-defaults/")]
    original_sources = [s for s in blueprint["sources"] if s["file"].startswith("extensions/theme-defaults/")]

    extensions_root = os.path.join(args.vscode_app, "Contents", "Resources", "app", "extensions")
    with open(os.path.join(args.vscode_app, "Contents", "Resources", "app", "package.json"), encoding="utf-8") as handle:
        vscode_version = json.load(handle)["version"]

    assets, sources, licenses, notices = list(original), list(original_sources), [], []
    for folder, wanted in BUILTIN.items():
        source = directory_source(f"extensions/{folder}", os.path.join(extensions_root, folder))
        assets += theme_assets(source, wanted, licenses)
        sources += [{"file": f"extensions/{folder}/{p}", "sha256": hashlib.sha256(d).hexdigest(), "bytes": len(d)} for p, d in sorted(source.files.items())]
    for extension_id, wanted in COMMUNITY.items():
        path, version = find_vsix(args.vsix_dir, extension_id)
        label = f"vsix/{extension_id}@{version}"
        source = vsix_source(label, path)
        assets += theme_assets(source, wanted, licenses)
        notices.append((extension_id, version, license_text(source)))
        sources += [{"file": f"{label}/{source.root}{p}", "sha256": hashlib.sha256(d).hexdigest(), "bytes": len(d)} for p, d in sorted(source.files.items())]

    ids = [a["id"] for a in assets]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate theme ids")
    if len(assets) > MAX_ASSETS:
        raise SystemExit(f"{len(assets)} assets exceed the loader limit of {MAX_ASSETS}")

    blueprint["assets"] = assets
    blueprint["sources"] = sources
    blueprint["extensions"] = {
        "adapter": "vscode-contributed-themes@1",
        "manifest": "extensions/theme-defaults/package.json",
        "additional": [{"source": label, "publisher": publisher, "version": version, "license": lic}
                       for label, publisher, version, lic in licenses],
    }
    data = (json.dumps(blueprint, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    with open(blueprint_path, "wb") as handle:
        handle.write(data)
    with open(os.path.join(RESOURCES, "vscode-themes.sha256"), "w", encoding="utf-8") as handle:
        handle.write(hashlib.sha256(data).hexdigest() + "\n")

    lines = ["Third-party Visual Studio Code color themes", "",
             f"Built-in theme extensions from Visual Studio Code {vscode_version} ({', '.join(BUILTIN)}) are",
             "distributed under the Microsoft MIT license in vscode-themes-license.txt.", "",
             "MShell bundles only workbench color values from the following Marketplace extensions. Token",
             "colors, icons and other files are not included.", ""]
    for extension_id, version, text in notices:
        lines += ["=" * 72, f"{extension_id} {version}", "=" * 72, "", text, ""]
    with open(os.path.join(RESOURCES, "vscode-community-themes-licenses.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    print(f"{len(assets)} assets ({len(assets) - len(original)} added), {len(sources)} source files")


if __name__ == "__main__":
    main()
