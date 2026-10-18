import json
from pathlib import Path
import re
import shutil

import pytest

from validate_release_versions import VersionError, main, validate


REPO_ROOT = Path(__file__).resolve().parents[3]


def copy_release_sources(destination: Path) -> None:
    config = "scripts/docs-generators/config.json"
    (destination / config).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(REPO_ROOT / config, destination / config)
    shutil.copy(REPO_ROOT / ".release-please-manifest.json", destination)
    shutil.copy(REPO_ROOT / "release-please-config.json", destination)
    for relative in (
        "uv.lock",
        "libs/cua-bench/uv.lock",
        "libs/cua-bench/pyproject.toml",
        "libs/python/agent/pyproject.toml",
        "libs/python/core/pyproject.toml",
        "libs/python/bench-ui/pyproject.toml",
        "libs/python/som/pyproject.toml",
        "libs/python/cua-sandbox-apps/pyproject.toml",
        "libs/python/cua-sandbox-apps/uv.lock",
        "libs/typescript/core/package.json",
        "libs/typescript/playground/package.json",
        "libs/cuabot/package.json",
    ):
        (destination / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO_ROOT / relative, destination / relative)
    for filename in ("VERSION", "pyproject.toml", "uv.lock", "cua_sandbox/__init__.py"):
        relative = Path("libs/python/cua-sandbox") / filename
        (destination / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO_ROOT / relative, destination / relative)
    release_state = ".github/release-state"
    shutil.copytree(REPO_ROOT / release_state, destination / release_state)
    for relative in ("libs/cua-driver", "libs/lume"):
        source = REPO_ROOT / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(
            source,
            target,
            ignore=shutil.ignore_patterns(".build", ".swiftpm", "target", "node_modules"),
        )
    for relative in (
        "libs/cua/VERSION",
        "libs/cua/python/pyproject.toml",
        "libs/cua/python/src/cua/__init__.py",
        "libs/cua/typescript/package.json",
        "libs/cua/typescript/package-lock.json",
        "libs/cua/Cargo.toml",
        "libs/cua/Cargo.lock",
        *(str(m.relative_to(REPO_ROOT)) for m in sorted((REPO_ROOT / "libs/cua").glob("crates/*/Cargo.toml"))),
        "apps/cua-spaces-macos/VERSION",
        "apps/cua-spaces-macos/Support/Info.plist",
        "apps/cua-spaces/package.json",
        "apps/cua-spaces/src-tauri/tauri.conf.json",
        "apps/cua-spaces/src-tauri/Cargo.toml",
        "apps/cua-spaces/src-tauri/Cargo.lock",
    ):
        (destination / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO_ROOT / relative, destination / relative)
    spacesd = REPO_ROOT / "libs/cua-spacesd"
    for source in (
        spacesd / "VERSION",
        spacesd / "Cargo.toml",
        spacesd / "Cargo.lock",
        *spacesd.glob("crates/*/Cargo.toml"),
        *spacesd.glob("tests/*/Cargo.lock"),
    ):
        target = destination / source.relative_to(REPO_ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    for product in ("cua-driver", "lume"):
        docs = f"docs/content/docs/{product}/reference"
        shutil.copytree(REPO_ROOT / docs, destination / docs)


def test_current_release_versions_agree():
    validate(REPO_ROOT, "all")


def test_sandbox_product_cli_accepts_current_versions():
    assert main(["--repo-root", str(REPO_ROOT), "--product", "sandbox"]) == 0


def test_perception_product_cli_accepts_current_versions():
    assert main(["--repo-root", str(REPO_ROOT), "--product", "perception"]) == 0


@pytest.mark.parametrize("product", ["perception", "all"])
def test_perception_versions_use_independent_authority(tmp_path: Path, product: str):
    copy_release_sources(tmp_path)
    validate(tmp_path, product)


@pytest.mark.parametrize("product", ["perception", "all"])
@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("VERSION", "Cua Perception expects 9.9.9"),
        ("Cargo.toml", "Cargo.toml=9.9.9"),
        ("Cargo.lock", "Cargo.lock:cua-perception=9.9.9"),
        (".release-please-manifest.json", ".release-please-manifest.json=9.9.9"),
    ],
)
def test_perception_version_drift_fails(
    tmp_path: Path, product: str, source: str, expected: str
):
    copy_release_sources(tmp_path)
    base = tmp_path / "libs/cua-driver/rust/crates/cua-perception"
    current = (base / "VERSION").read_text().strip()
    if source == ".release-please-manifest.json":
        path = tmp_path / source
        manifest = json.loads(path.read_text())
        manifest["libs/cua-driver/rust/crates/cua-perception"] = "9.9.9"
        path.write_text(json.dumps(manifest))
    elif source == "Cargo.lock":
        path = tmp_path / "libs/cua-driver/rust/Cargo.lock"
        path.write_text(
            re.sub(
                rf'(\[\[package\]\]\nname = "cua-perception"\nversion = "){re.escape(current)}("\n)',
                r"\g<1>9.9.9\2",
                path.read_text(),
                count=1,
            )
        )
    else:
        path = base / source
        path.write_text(path.read_text().replace(current, "9.9.9", 1))

    with pytest.raises(VersionError, match=re.escape(expected)):
        validate(tmp_path, product)


@pytest.mark.parametrize("product", ["sandbox", "all"])
@pytest.mark.parametrize(
    "source",
    ["VERSION", "pyproject.toml", "uv.lock", "cua_sandbox/__init__.py", ".release-please-manifest.json"],
)
def test_sandbox_version_drift_fails(tmp_path: Path, product: str, source: str):
    copy_release_sources(tmp_path)
    base = tmp_path / "libs/python/cua-sandbox"
    current = (base / "VERSION").read_text().strip()
    if source == ".release-please-manifest.json":
        path = tmp_path / source
        manifest = json.loads(path.read_text())
        manifest["libs/python/cua-sandbox"] = "9.9.9"
        path.write_text(json.dumps(manifest))
    else:
        path = base / source
        path.write_text(path.read_text().replace(current, "9.9.9"))

    expected = "Sandbox expects 9.9.9" if source == "VERSION" else f"{source}=9.9.9"
    with pytest.raises(VersionError, match=re.escape(expected)):
        validate(tmp_path, product)


def test_spacesd_product_cli_accepts_current_versions():
    assert main(["--repo-root", str(REPO_ROOT), "--product", "spacesd"]) == 0


@pytest.mark.parametrize("product", ["spacesd", "all"])
@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("VERSION", "cua-spacesd expects 9.9.9"),
        ("Cargo.toml", "Cargo.toml=9.9.9"),
        ("Cargo.lock", "Cargo.lock:cua-spacesd=9.9.9"),
        ("tests/teleport-e2e/Cargo.lock", "tests/teleport-e2e/Cargo.lock:cua-spacesd-server=9.9.9"),
        (".release-please-manifest.json", ".release-please-manifest.json=9.9.9"),
    ],
)
def test_spacesd_version_drift_fails(
    tmp_path: Path, product: str, source: str, expected: str
):
    copy_release_sources(tmp_path)
    base = tmp_path / "libs/cua-spacesd"
    current = (base / "VERSION").read_text().strip()
    if source == ".release-please-manifest.json":
        path = tmp_path / source
        manifest = json.loads(path.read_text())
        manifest["libs/cua-spacesd"] = "9.9.9"
        path.write_text(json.dumps(manifest))
    elif source == "Cargo.toml":
        path = base / source
        path.write_text(path.read_text().replace(f'version = "{current}"', 'version = "9.9.9"', 1))
    elif source == "VERSION":
        (base / source).write_text("9.9.9\n")
    else:
        name = "cua-spacesd" if source == "Cargo.lock" else "cua-spacesd-server"
        path = base / source
        path.write_text(
            path.read_text().replace(
                f'name = "{name}"\nversion = "{current}"', f'name = "{name}"\nversion = "9.9.9"'
            )
        )
    with pytest.raises(VersionError, match=re.escape(expected)):
        validate(tmp_path, product)


def test_version_drift_fails_with_the_source_name(tmp_path: Path):
    copy_release_sources(tmp_path)
    path = tmp_path / "libs/lume/src/Main.swift"
    current = (tmp_path / "libs/lume/VERSION").read_text().strip()
    path.write_text(path.read_text().replace(f'"{current}"', '"9.9.9"'))
    with pytest.raises(VersionError, match="src/Main.swift=9.9.9"):
        validate(tmp_path, "lume")


def test_checked_in_withdrawn_versions_are_exact_and_explained():
    path = REPO_ROOT / ".github/release-state/cua-driver-rs-withdrawn-versions"
    entries = [
        line for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    assert entries
    for line in entries:
        version, _, reason = line.partition("#")
        assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version.strip())
        assert reason.strip(), f"withdrawn {version.strip()} needs a reason"


SDK_AND_SPACES_SOURCES = (
    ".release-please-manifest.json",
    "libs/cua/VERSION",
    "libs/cua/python/pyproject.toml",
    "libs/cua/python/src/cua/__init__.py",
    "libs/cua/typescript/package.json",
    "libs/cua/typescript/package-lock.json",
    "libs/cua/Cargo.toml",
    "libs/cua/Cargo.lock",
    *(str(m.relative_to(REPO_ROOT)) for m in sorted((REPO_ROOT / "libs/cua").glob("crates/*/Cargo.toml"))),
    "apps/cua-spaces-macos/VERSION",
    "apps/cua-spaces-macos/Support/Info.plist",
    "apps/cua-spaces/package.json",
    "apps/cua-spaces/src-tauri/tauri.conf.json",
    "apps/cua-spaces/src-tauri/Cargo.toml",
    "apps/cua-spaces/src-tauri/Cargo.lock",
)


def test_sdk_and_spaces_products_accept_current_versions():
    assert main(["--repo-root", str(REPO_ROOT), "--product", "sdk"]) == 0
    assert main(["--repo-root", str(REPO_ROOT), "--product", "spaces"]) == 0


@pytest.mark.parametrize(
    ("product", "relative"),
    [
        ("sdk", "libs/cua/typescript/package.json"),
        ("sdk", "libs/cua/python/pyproject.toml"),
        ("spaces", "apps/cua-spaces/src-tauri/tauri.conf.json"),
        ("spaces", "apps/cua-spaces/package.json"),
    ],
)
def test_sdk_and_spaces_version_drift_fails(tmp_path: Path, product: str, relative: str):
    for source in SDK_AND_SPACES_SOURCES:
        target = tmp_path / source
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO_ROOT / source, target)
    path = tmp_path / relative
    text = path.read_text()
    marker = 'version = "' if relative.endswith(".toml") else '"version": "'
    assert marker in text
    path.write_text(text.replace(marker, marker + "9.9.9-drift", 1))
    assert main(["--repo-root", str(tmp_path), "--product", product]) == 1


def test_spaces_macos_info_plist_drift_fails(tmp_path: Path):
    for source in SDK_AND_SPACES_SOURCES:
        target = tmp_path / source
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO_ROOT / source, target)
    plist = tmp_path / "apps/cua-spaces-macos/Support/Info.plist"
    text = plist.read_text()
    marker = "<key>CFBundleShortVersionString</key>\n\t<string>"
    assert marker in text
    plist.write_text(text.replace(marker, marker + "9.9.9-drift", 1))
    with pytest.raises(VersionError, match="Info.plist"):
        validate(tmp_path, "spaces")


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("VERSION", "cua SDK expects 9.9.9"),
        ("python/pyproject.toml", "python/pyproject.toml=9.9.9"),
        ("typescript/package-lock.json", "typescript/package-lock.json=9.9.9"),
        ("Cargo.toml", "Cargo.toml:workspace.package.version=9.9.9"),
        ("crates/cua-sdk/Cargo.toml", "crates/cua-sdk/Cargo.toml:dependencies.cua-proto=9.9.9"),
    ],
)
def test_sdk_version_drift_fails(tmp_path: Path, source: str, expected: str):
    copy_release_sources(tmp_path)
    path = tmp_path / "libs/cua" / source
    current = (tmp_path / "libs/cua/VERSION").read_text().strip()
    if source == "VERSION":
        path.write_text("9.9.9\n")
    elif source.endswith(".json"):
        data = json.loads(path.read_text())
        data["version"] = "9.9.9"
        path.write_text(json.dumps(data))
    else:
        path.write_text(path.read_text().replace(f'version = "{current}"', 'version = "9.9.9"', 1))
    with pytest.raises(VersionError, match=re.escape(expected)):
        validate(tmp_path, "sdk")
