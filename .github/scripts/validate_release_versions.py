#!/usr/bin/env python3
"""Verify that checked-in product release versions agree."""

from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10 and earlier
    import tomli as tomllib
from typing import Sequence

from sync_driver_release_docs import driver_reference_paths
from sync_lume_release_docs import lume_reference_paths


class VersionError(RuntimeError):
    """Checked-in version sources do not describe one release."""


def read_match(path: Path, pattern: str) -> str:
    match = re.search(pattern, path.read_text(), re.MULTILINE)
    if not match:
        raise VersionError(f"could not read a release version from {path}")
    return match.group(1)


def require_equal(product: str, expected: str, values: dict[str, str]) -> None:
    mismatches = {name: value for name, value in values.items() if value != expected}
    if mismatches:
        details = ", ".join(f"{name}={value}" for name, value in sorted(mismatches.items()))
        raise VersionError(f"{product} expects {expected}; mismatched sources: {details}")


def stable_version_tuple(version: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise VersionError(f"expected an exact stable x.y.z version, got {version!r}")
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


def driver_versions(root: Path) -> tuple[str, dict[str, str]]:
    base = root / "libs/cua-driver"
    docs_dir = "docs/content/docs/cua-driver/reference"
    expected = (base / "rust/VERSION").read_text().strip()
    cargo = tomllib.loads((base / "rust/Cargo.toml").read_text())
    python_project = tomllib.loads((base / "python/pyproject.toml").read_text())
    typescript_package = json.loads(
        (base / "typescript/package.json").read_text()
    )
    typescript_lock = json.loads(
        (base / "typescript/package-lock.json").read_text()
    )
    values = {
        "rust/Cargo.toml": str(cargo["workspace"]["package"]["version"]),
        "python/pyproject.toml": str(python_project["project"]["version"]),
        "python/src/cua_driver/__init__.py": read_match(
            base / "python/src/cua_driver/__init__.py", r'^__version__\s*=\s*"([^"]+)"'
        ),
        "typescript/package.json": str(typescript_package["version"]),
        "typescript/package-lock.json": str(typescript_lock["version"]),
        "typescript/package-lock.json:root": str(
            typescript_lock["packages"][""]["version"]
        ),
        "rust/Skills/cua-driver/SKILL.md": read_match(
            base / "rust/Skills/cua-driver/SKILL.md",
            r"^version:\s*([^\s#]+)",
        ),
    }
    for relative in driver_reference_paths(root):
        values[f"docs/{Path(relative).relative_to(docs_dir).as_posix()}:metadata"] = read_match(
            root / relative, r"^  Version: (\S+)$"
        )

    members = [base / "rust" / member for member in cargo["workspace"]["members"]]
    local_names = {
        tomllib.loads((member / "Cargo.toml").read_text())["package"]["name"] for member in members
    }
    local_names.discard("cua-perception")
    lock = tomllib.loads((base / "rust/Cargo.lock").read_text())
    for package in lock["package"]:
        if package["name"] in local_names:
            values[f"rust/Cargo.lock:{package['name']}"] = str(package["version"])
    missing = local_names - {
        key.split(":", 1)[1] for key in values if key.startswith("rust/Cargo.lock:")
    }
    if missing:
        raise VersionError(f"Cargo.lock is missing workspace packages: {sorted(missing)}")
    return expected, values


def perception_versions(root: Path) -> tuple[str, dict[str, str]]:
    base = root / "libs/cua-driver/rust/crates/cua-perception"
    expected = (base / "VERSION").read_text().strip()
    project = tomllib.loads((base / "Cargo.toml").read_text())
    lock = tomllib.loads((root / "libs/cua-driver/rust/Cargo.lock").read_text())
    packages = [entry for entry in lock["package"] if entry["name"] == "cua-perception"]
    if len(packages) != 1:
        raise VersionError("Cargo.lock must contain exactly one cua-perception package")
    stable_version_tuple(expected)
    return expected, {
        "Cargo.toml": str(project["package"]["version"]),
        "Cargo.lock:cua-perception": str(packages[0]["version"]),
    }


def lume_versions(root: Path) -> tuple[str, dict[str, str]]:
    base = root / "libs/lume"
    docs_dir = "docs/content/docs/lume/reference"
    expected = (base / "VERSION").read_text().strip()
    values = {
        "src/Main.swift": read_match(
            base / "src/Main.swift", r'static let current: String = "([^"]+)"'
        ),
        "docs/http-api.mdx:body": read_match(
            root / docs_dir / "http-api.mdx", r"Documented against Lume \*\*(\S+)\*\*\."
        ),
    }
    for relative in lume_reference_paths(root):
        values[f"docs/{Path(relative).relative_to(docs_dir).as_posix()}:metadata"] = read_match(
            root / relative, r"^  Version: (\S+)$"
        )
    return expected, values


def sandbox_versions(root: Path) -> tuple[str, dict[str, str]]:
    base = root / "libs/python/cua-sandbox"
    expected = (base / "VERSION").read_text().strip()
    project = tomllib.loads((base / "pyproject.toml").read_text())
    lock = tomllib.loads((base / "uv.lock").read_text())
    packages = [entry for entry in lock["package"] if entry["name"] == "cua-sandbox"]
    if len(packages) != 1 or packages[0].get("source") != {"editable": "."}:
        raise VersionError("Sandbox uv.lock must contain exactly one editable root package")
    stable_version_tuple(expected)
    return expected, {
        "pyproject.toml": str(project["project"]["version"]),
        "uv.lock": str(packages[0]["version"]),
        "cua_sandbox/__init__.py": read_match(
            base / "cua_sandbox/__init__.py", r'^__version__\s*=\s*"([^"]+)"'
        ),
    }


def spacesd_versions(root: Path) -> tuple[str, dict[str, str]]:
    base = root / "libs/cua-spacesd"
    expected = (base / "VERSION").read_text().strip()
    cargo = tomllib.loads((base / "Cargo.toml").read_text())
    names = set()
    for member in cargo["workspace"]["members"]:
        package = tomllib.loads((base / member / "Cargo.toml").read_text())["package"]
        if package.get("version") == {"workspace": True}:
            names.add(package["name"])
    if "cua-spacesd" not in names:
        raise VersionError("cua-spacesd must inherit the workspace version")
    stable_version_tuple(expected)
    values = {"Cargo.toml": str(cargo["workspace"]["package"]["version"])}
    # The standalone e2e workspaces lock the driver crates by path too.
    locks = [base / "Cargo.lock", *sorted((base / "tests").glob("*/Cargo.lock"))]
    for lock_path in locks:
        lock = tomllib.loads(lock_path.read_text())
        label = lock_path.relative_to(base).as_posix()
        for entry in lock["package"]:
            if entry["name"] in names and "source" not in entry:
                values[f"{label}:{entry['name']}"] = str(entry["version"])
    return expected, values


def sdk_versions(root: Path) -> tuple[str, dict[str, str]]:
    base = root / "libs/cua"
    expected = (base / "VERSION").read_text().strip()
    stable_version_tuple(expected)
    project = tomllib.loads((base / "python/pyproject.toml").read_text())
    package = json.loads((base / "typescript/package.json").read_text())
    lock = json.loads((base / "typescript/package-lock.json").read_text())
    return expected, {
        "python/pyproject.toml": str(project["project"]["version"]),
        "python/src/cua/__init__.py": read_match(
            base / "python/src/cua/__init__.py", r'^__version__\s*=\s*"([^"]+)"'
        ),
        "typescript/package.json": str(package["version"]),
        "typescript/package-lock.json": str(lock["version"]),
        "typescript/package-lock.json:root": str(lock["packages"][""]["version"]),
        **sdk_crate_versions(base),
    }


def sdk_crate_versions(base: Path) -> dict[str, str]:
    """The libs/cua Cargo workspace releases at the SDK version: its package
    version, the versions its crates require of each other, and their
    entries in libs/cua/Cargo.lock (cua-sdk and the crates it needs are
    published to crates.io at it)."""
    workspace = tomllib.loads((base / "Cargo.toml").read_text())["workspace"]
    values = {"Cargo.toml:workspace.package.version": str(workspace["package"]["version"])}
    for name, dep in workspace["dependencies"].items():
        if isinstance(dep, dict) and str(dep.get("path", "")).startswith("crates/") and "version" in dep:
            values[f"Cargo.toml:workspace.dependencies.{name}"] = str(dep["version"])
    sdk = tomllib.loads((base / "crates/cua-sdk/Cargo.toml").read_text())
    for name, dep in sdk.get("dependencies", {}).items():
        if isinstance(dep, dict) and "path" in dep and "version" in dep:
            values[f"crates/cua-sdk/Cargo.toml:dependencies.{name}"] = str(dep["version"])
    members = {
        tomllib.loads(manifest.read_text())["package"]["name"]
        for manifest in base.glob("crates/*/Cargo.toml")
    }
    lock = tomllib.loads((base / "Cargo.lock").read_text())
    for entry in lock["package"]:
        if entry["name"] in members and "source" not in entry:
            values[f"Cargo.lock:{entry['name']}"] = str(entry["version"])
    return values


def spaces_app_versions(root: Path) -> tuple[str, dict[str, str]]:
    # Release Please drives Cua Spaces from the macOS app (component
    # `cua-spaces` at apps/cua-spaces-macos); the Tauri app shares its version.
    macos = root / "apps/cua-spaces-macos"
    expected = (macos / "VERSION").read_text().strip()
    stable_version_tuple(expected)
    with (macos / "Support/Info.plist").open("rb") as info_file:
        info = plistlib.load(info_file)
    base = root / "apps/cua-spaces"
    package = json.loads((base / "package.json").read_text())
    tauri = json.loads((base / "src-tauri/tauri.conf.json").read_text())
    cargo = tomllib.loads((base / "src-tauri/Cargo.toml").read_text())
    lock = tomllib.loads((base / "src-tauri/Cargo.lock").read_text())
    locked = [entry for entry in lock["package"] if entry["name"] == cargo["package"]["name"]]
    if len(locked) != 1:
        raise VersionError("Cua Spaces Cargo.lock must lock the app crate exactly once")
    return expected, {
        "apps/cua-spaces-macos/Support/Info.plist": str(info["CFBundleShortVersionString"]),
        "apps/cua-spaces/package.json": str(package["version"]),
        "apps/cua-spaces/src-tauri/tauri.conf.json": str(tauri["version"]),
        "apps/cua-spaces/src-tauri/Cargo.toml": str(cargo["package"]["version"]),
        "apps/cua-spaces/src-tauri/Cargo.lock": str(locked[0]["version"]),
    }


# Packages whose Release Please entry is the whole version contract: the
# manifest version must equal every extra file Release Please bumps.
CONFIG_ONLY_PACKAGES = (
    "libs/python/agent",
    "libs/python/core",
    "libs/cua-bench",
    "libs/python/bench-ui",
    "libs/python/som",
    "libs/python/cua-sandbox-apps",
    "libs/typescript/core",
    "libs/typescript/playground",
    "libs/cuabot",
)
LOCK_ENTRY = re.compile(r"^\$\.package\[\?\(@\.name\.value=='([^']+)'\)\]\.version$")


def extra_file_version(root: Path, package_path: str, extra: dict) -> str:
    path = extra["path"]
    file = root / path.lstrip("/") if path.startswith("/") else root / package_path / path
    jsonpath = extra["jsonpath"]
    if extra["type"] == "json":
        data = json.loads(file.read_text())
    elif extra["type"] == "toml":
        data = tomllib.loads(file.read_text())
    else:
        raise VersionError(f"{package_path}: unsupported extra-file type {extra['type']}")
    lock = LOCK_ENTRY.match(jsonpath)
    if lock:
        entries = [e for e in data.get("package", []) if e.get("name") == lock.group(1)]
        if len(entries) != 1:
            raise VersionError(f"{file.relative_to(root)} must lock {lock.group(1)} exactly once")
        return str(entries[0]["version"])
    node = data
    for key in jsonpath.removeprefix("$.").split("."):
        node = node[key]
    return str(node)


def config_only_package_versions(root: Path) -> dict[str, tuple[str, dict[str, str]]]:
    config = json.loads((root / "release-please-config.json").read_text())
    manifest = json.loads((root / ".release-please-manifest.json").read_text())
    results = {}
    for package_path in CONFIG_ONLY_PACKAGES:
        package = config["packages"].get(package_path)
        if package is None:
            raise VersionError(f"{package_path} is not a Release Please package")
        expected = str(manifest[package_path])
        stable_version_tuple(expected)
        values = {
            f"{extra['path']}:{extra['jsonpath']}": extra_file_version(root, package_path, extra)
            for extra in package.get("extra-files", [])
        }
        if not values:
            raise VersionError(f"{package_path} has no version file for Release Please to bump")
        results[package_path] = (expected, values)
    return results


def validate(root: Path, product: str) -> None:
    manifest = json.loads((root / ".release-please-manifest.json").read_text())
    if product in {"all", "driver"}:
        expected, values = driver_versions(root)
        values[".release-please-manifest.json"] = str(manifest["libs/cua-driver"])
        require_equal("Cua Driver", expected, values)
    if product in {"all", "perception"}:
        expected, values = perception_versions(root)
        values[".release-please-manifest.json"] = str(
            manifest["libs/cua-driver/rust/crates/cua-perception"]
        )
        require_equal("Cua Perception", expected, values)
    if product in {"all", "lume"}:
        expected, values = lume_versions(root)
        values[".release-please-manifest.json"] = str(manifest["libs/lume"])
        require_equal("Lume", expected, values)
    if product in {"all", "sandbox"}:
        expected, values = sandbox_versions(root)
        values[".release-please-manifest.json"] = str(manifest["libs/python/cua-sandbox"])
        require_equal("Sandbox", expected, values)
    if product in {"all", "spacesd"}:
        expected, values = spacesd_versions(root)
        values[".release-please-manifest.json"] = str(manifest["libs/cua-spacesd"])
        require_equal("cua-spacesd", expected, values)
    if product in {"all", "sdk"}:
        expected, values = sdk_versions(root)
        values[".release-please-manifest.json"] = str(manifest["libs/cua"])
        require_equal("cua SDK", expected, values)
    if product in {"all", "packages"}:
        for package_path, (expected, values) in config_only_package_versions(root).items():
            require_equal(package_path, expected, values)
    if product in {"all", "spaces"}:
        expected, values = spaces_app_versions(root)
        values[".release-please-manifest.json"] = str(manifest["apps/cua-spaces-macos"])
        require_equal("Cua Spaces app", expected, values)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--product",
        choices=(
            "all", "driver", "perception", "lume", "sandbox", "spacesd", "sdk", "spaces", "packages"
        ),
        default="all",
    )
    args = parser.parse_args(argv)
    try:
        validate(args.repo_root.resolve(), args.product)
    except (KeyError, OSError, VersionError, ValueError) as error:
        print(f"release version error: {error}", file=sys.stderr)
        return 1
    print(f"release versions agree for {args.product}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
