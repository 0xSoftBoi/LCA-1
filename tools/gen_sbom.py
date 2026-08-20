#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the deterministic LCA-1 CycloneDX 1.6 supply-chain SBOM.

The SBOM covers the whole declared stack, not only software: the npm
lockfile, the Python project metadata, the pinned git submodules, the
hardware and IP components named in the Rev-A fabrication contract, the
build/verification toolchain, and every commit-pinned GitHub Action.

Every fact in the emitted document is read from a file committed to this
repository (or from the git index for submodule gitlinks). Nothing is
fetched from the network and nothing is inferred from an installed
environment, so two runs at the same commit produce byte-identical output
and ``--check`` is a real drift gate.

Deliberate omissions, both required for determinism:

* ``metadata.timestamp`` is not emitted. CycloneDX makes it optional and a
  wall-clock value would make ``--check`` fail on every run.
* the repository commit is not embedded. A file cannot contain the hash of
  the commit that adds it; the commit is bound externally by the workflow
  artifact name and by the SLSA provenance attestation.

Usage::

    python3 tools/gen_sbom.py                     # write docs/sbom.cdx.json
    python3 tools/gen_sbom.py --output PATH       # write elsewhere
    python3 tools/gen_sbom.py --check             # fail on drift
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Iterable

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11 only
    print(
        "ERROR tools/gen_sbom.py needs Python 3.11+ for stdlib tomllib "
        "(CI pins 3.12.12)",
        file=sys.stderr,
    )
    raise

ROOT = Path(__file__).resolve().parents[1]

GENERATOR_NAME = "tools/gen_sbom.py"
GENERATOR_VERSION = "1.0.0"
SPEC_VERSION = "1.6"
BOM_VERSION = 1

REPO_URL = "https://github.com/0xSoftBoi/LCA-1"
SUPPLIER = "Suwappu Labs"
AUTHOR = "Suwappu Labs and the LCA-1 contributors"

DEFAULT_OUTPUT = ROOT / "docs" / "sbom.cdx.json"

PACKAGE_JSON = Path("package.json")
PACKAGE_LOCK = Path("package-lock.json")
PYPROJECT = Path("pyproject.toml")
GITMODULES = Path(".gitmodules")
RELEASE_JSON = Path("fabrication/rev_a_release.json")
PACKAGE_CONTRACT_JSON = Path("fabrication/rev_a_package.json")
HARDEN_CONFIG = Path("hardening/lca_butterfly/config.json")
WORKFLOW_DIR = Path(".github/workflows")
NOTICE = Path("NOTICE")

# Third-party / derived files inventoried in NOTICE, with the license NOTICE
# actually records for each. Hashing them makes NOTICE's inventory verifiable
# instead of merely asserted.
NOTICE_FILES: tuple[tuple[str, str, str], ...] = (
    (
        "firmware/fips202_lca.c",
        "CC0-1.0",
        "PQClean-derived FIPS 202 permutation; public domain per NOTICE.",
    ),
    (
        "firmware/fips202.h",
        "CC0-1.0",
        "PQClean-derived FIPS 202 header; public domain per NOTICE.",
    ),
    (
        "verification/vectors/external/cctv_mlkem768_ntt.json",
        "CC0-1.0",
        "C2SP/CCTV ML-KEM-768 intermediate values; source URL and SHA-256 "
        "recorded inside the file.",
    ),
)

NOASSERTION_REASON = "lca1:license:noassertion-reason"

_SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
_USES_RE = re.compile(
    r"uses:\s*([A-Za-z0-9._\-]+/[A-Za-z0-9._\-/]+)@([0-9a-f]{40})\s*#\s*(v\S+)"
)
_USES_ANY_RE = re.compile(r"uses:\s*(\S+)")
_REPOSITORY_RE = re.compile(r"^\s*repository:\s*([A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+)\s*$")
_REF_RE = re.compile(r"^\s*ref:\s*([0-9a-f]{40})\s*$")
_CONTAINER_RE = re.compile(r"((?:ghcr\.io|docker\.io|quay\.io)/[A-Za-z0-9._/\-]+:[A-Za-z0-9._\-]+)")
_PIP_RE = re.compile(r"pip install\s+([A-Za-z0-9._\-]+)==([A-Za-z0-9._\-]+)")
_APT_RE = re.compile(r"apt-get install\s+([^&|\n]+)")
_PYVER_RE = re.compile(r'python-version:\s*"([^"]+)"')


# --------------------------------------------------------------------------
# small builders
# --------------------------------------------------------------------------


def _prop(name: str, value: Any) -> dict[str, str]:
    return {"name": name, "value": str(value)}


def _spdx(*ids: str) -> list[dict[str, Any]]:
    return [{"license": {"id": identifier}} for identifier in ids]


def _reference(kind: str, url: str) -> dict[str, str]:
    return {"type": kind, "url": url}


def component(
    bom_ref: str,
    ctype: str,
    name: str,
    *,
    version: str | None = None,
    group: str | None = None,
    description: str | None = None,
    licenses: list[dict[str, Any]] | None = None,
    noassertion_reason: str | None = None,
    purl: str | None = None,
    hashes: list[dict[str, str]] | None = None,
    external_references: list[dict[str, str]] | None = None,
    properties: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    """Build one CycloneDX component with a mandatory licensing decision.

    Either an SPDX licence list or an explicit NOASSERTION reason must be
    supplied: an unexplained licence gap is not an acceptable SBOM entry for
    this repository.
    """
    if (licenses is None) == (noassertion_reason is None):
        raise ValueError(
            f"component {bom_ref}: supply exactly one of licenses / "
            "noassertion_reason"
        )
    props = list(properties or [])
    if noassertion_reason is not None:
        licenses = [{"license": {"name": "NOASSERTION"}}]
        props.append(_prop(NOASSERTION_REASON, noassertion_reason))

    entry: dict[str, Any] = {"bom-ref": bom_ref, "type": ctype, "name": name}
    if group is not None:
        entry["group"] = group
    if version is not None:
        entry["version"] = version
    if description is not None:
        entry["description"] = description
    entry["licenses"] = licenses
    if purl is not None:
        entry["purl"] = purl
    if hashes:
        entry["hashes"] = hashes
    if external_references:
        entry["externalReferences"] = external_references
    if props:
        entry["properties"] = sorted(props, key=lambda item: (item["name"], item["value"]))
    return entry


def _read_json(root: Path, relative: Path) -> Any:
    return json.loads((root / relative).read_text(encoding="utf-8"))


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# --------------------------------------------------------------------------
# collectors
# --------------------------------------------------------------------------


def collect_npm(root: Path) -> list[dict[str, Any]]:
    """npm dependencies exactly as pinned by package-lock.json."""
    lock = _read_json(root, PACKAGE_LOCK)
    components: list[dict[str, Any]] = []
    for path, entry in sorted(lock.get("packages", {}).items()):
        if not path.startswith("node_modules/"):
            continue  # the "" entry is the first-party root component
        name = path[len("node_modules/") :]
        version = entry.get("version")
        group, _, bare = name.rpartition("/")
        purl_name = f"{group.replace('@', '%40')}/{bare}" if group else bare

        hashes: list[dict[str, str]] = []
        integrity = entry.get("integrity")
        properties = [_prop("lca1:source", PACKAGE_LOCK.as_posix())]
        if integrity:
            properties.append(_prop("lca1:npm:integrity", integrity))
            algorithm, _, encoded = integrity.partition("-")
            try:
                digest = binascii.hexlify(base64.b64decode(encoded, validate=True)).decode()
            except (binascii.Error, ValueError):
                digest = ""
            alg_map = {"sha512": "SHA-512", "sha256": "SHA-256", "sha1": "SHA-1"}
            if digest and algorithm in alg_map:
                hashes.append({"alg": alg_map[algorithm], "content": digest})

        references: list[dict[str, str]] = []
        if entry.get("resolved"):
            references.append(_reference("distribution", entry["resolved"]))

        declared = entry.get("license")
        licenses = _spdx(declared) if declared else None
        reason = None if declared else "package-lock.json records no license field"

        if name == "@yowasp/yosys":
            # The lockfile is also the pin for the synthesis/formal toolchain:
            # the npm version encodes the Yosys release it packages.
            properties.append(_prop("lca1:role", "toolchain:synthesis-and-formal"))
            properties.append(_prop("lca1:yosys:upstream-version", version.split(".")[0] + "." + version.split(".")[1]))
            properties.append(_prop("lca1:toolchain:invocation", "tools/run_yosys.mjs"))

        components.append(
            component(
                f"npm/{name}@{version}",
                "application" if name == "@yowasp/yosys" else "library",
                bare,
                group=group or None,
                version=version,
                licenses=licenses,
                noassertion_reason=reason,
                purl=f"pkg:npm/{purl_name}@{version}",
                hashes=hashes,
                external_references=references,
                properties=properties,
            )
        )
    return components


def collect_python(root: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Root component from pyproject.toml plus its declared build backend."""
    pyproject = tomllib.loads((root / PYPROJECT).read_text(encoding="utf-8"))
    project = pyproject["project"]
    build = pyproject.get("build-system", {})

    root_component = component(
        f"lca1@{project['version']}",
        "application",
        project["name"],
        version=project["version"],
        description=project["description"],
        licenses=_spdx("Apache-2.0"),
        purl=f"pkg:generic/{project['name']}@{project['version']}",
        external_references=[
            _reference("vcs", REPO_URL),
            _reference("website", REPO_URL),
            _reference("license", f"{REPO_URL}/blob/main/LICENSE"),
        ],
        properties=[
            _prop("SPDX-License-Identifier", "Apache-2.0"),
            _prop("lca1:python:requires-python", project["requires-python"]),
            _prop("lca1:python:runtime-dependencies", len(project.get("dependencies", []))),
            _prop("lca1:source", PYPROJECT.as_posix()),
        ],
    )

    extras: list[dict[str, Any]] = []
    for requirement in sorted(build.get("requires", [])):
        name = re.split(r"[<>=!~\[ ]", requirement, maxsplit=1)[0]
        extras.append(
            component(
                f"pypi/{name}",
                "library",
                name,
                noassertion_reason=(
                    "build-system requirement; pyproject.toml declares a version "
                    "range, not a license"
                ),
                properties=[
                    _prop("lca1:python:build-requirement", requirement),
                    _prop("lca1:source", PYPROJECT.as_posix()),
                ],
            )
        )
    return root_component, extras


def _git(root: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout


def parse_gitmodules(text: str) -> list[dict[str, str]]:
    """Parse .gitmodules without configparser (it mangles tab-indented keys)."""
    modules: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[submodule "):
            current = {"name": line.split('"')[1]}
            modules.append(current)
        elif current is not None and "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            current[key.strip()] = value.strip()
    return [module for module in modules if "path" in module]


def collect_submodules(root: Path) -> list[dict[str, Any]]:
    """Submodules with their pinned gitlink SHAs and honest checkout state."""
    gitmodules = root / GITMODULES
    if not gitmodules.is_file():
        return []
    modules = parse_gitmodules(gitmodules.read_text(encoding="utf-8"))

    # Pinned SHA comes from the committed gitlink, which exists whether or not
    # the submodule working tree was ever populated.
    pinned: dict[str, str] = {}
    tree = _git(root, "ls-tree", "HEAD", "--", *[module["path"] for module in modules])
    if tree:
        for line in tree.splitlines():
            meta, _, path = line.partition("\t")
            fields = meta.split()
            if len(fields) == 3 and fields[1] == "commit":
                pinned[path.strip()] = fields[2]

    # Checkout state comes from `git submodule status`: a leading "-" means the
    # working tree was never initialised, which is this repository's state.
    checked_out: dict[str, bool] = {}
    status = _git(root, "submodule", "status")
    if status:
        for line in status.splitlines():
            if not line:
                continue
            flag, body = line[0], line[1:].strip()
            parts = body.split()
            if len(parts) >= 2:
                checked_out[parts[1]] = flag != "-"

    # NOTICE is the repository's own licence statement for these submodules.
    declared_licenses = {
        "third_party/PQClean": (
            ["CC0-1.0", "MIT", "Apache-2.0"],
            "NOTICE: licensed per scheme, predominantly CC0-1.0 with some MIT "
            "and Apache-2.0 components",
        ),
        "third_party/picorv32": (["ISC"], "NOTICE: ISC, see the submodule COPYING file"),
    }

    components: list[dict[str, Any]] = []
    for module in sorted(modules, key=lambda item: item["path"]):
        path = module["path"]
        url = module.get("url", "")
        sha = pinned.get(path)
        present = checked_out.get(path)

        properties = [
            _prop("lca1:source", GITMODULES.as_posix()),
            _prop("lca1:submodule:path", path),
            _prop("lca1:submodule:url", url),
            _prop("lca1:submodule:sha-source", "git gitlink at HEAD" if sha else "unavailable"),
            _prop(
                "lca1:submodule:checked-out",
                "unknown" if present is None else str(present).lower(),
            ),
        ]
        if not sha:
            properties.append(
                _prop(
                    "lca1:submodule:gap",
                    "gitlink SHA unavailable: generated outside a git checkout",
                )
            )
        if present is False:
            properties.append(
                _prop(
                    "lca1:submodule:gap",
                    "working tree not populated; per-file contents and the "
                    "complete license inventory inside the submodule are not "
                    "covered by this SBOM",
                )
            )

        slug = url.removeprefix("https://github.com/").removesuffix(".git")
        purl = f"pkg:github/{slug}@{sha}" if sha and slug and "/" in slug else None

        spdx_ids, note = declared_licenses.get(path, ([], ""))
        licenses = _spdx(*spdx_ids) if spdx_ids else None
        reason = None if spdx_ids else "not inventoried in NOTICE"
        if note:
            properties.append(_prop("lca1:license:source", note))

        components.append(
            component(
                f"submodule/{path}@{sha or 'unpinned'}",
                "library",
                path.rsplit("/", 1)[-1],
                group="third_party",
                version=sha or "NOASSERTION",
                description=f"git submodule pinned at {path}",
                licenses=licenses,
                noassertion_reason=reason,
                purl=purl,
                external_references=[_reference("vcs", url)] if url else None,
                properties=properties,
            )
        )
    return components


def collect_hardware(root: Path) -> list[dict[str, Any]]:
    """PDK, cell library, SRAM macro, OpenFrame harness, and the Rev-A device."""
    release = _read_json(root, RELEASE_JSON)
    package = _read_json(root, PACKAGE_CONTRACT_JSON)
    harden = _read_json(root, HARDEN_CONFIG)

    route = release["route"]
    shell = route["shell"]
    memory = release["memory"]
    baseline = memory["baseline"]
    experiment = memory["experiment"]
    physical = package["package"]

    components: list[dict[str, Any]] = []

    components.append(
        component(
            f"hardware/device/{release['release_id']}",
            "device",
            release["release_id"],
            version=release["as_of"],
            description=release["program"]["purpose"],
            licenses=_spdx("Apache-2.0"),
            properties=[
                _prop("lca1:hardware:kind", "asic-release-contract"),
                _prop("lca1:release:status", release["release_status"]),
                _prop("lca1:route:vendor", route["vendor"]),
                _prop("lca1:route:service", route["service"]),
                _prop("lca1:route:shuttle", route["shuttle"]),
                _prop("lca1:route:process", route["process"]),
                _prop("lca1:route:process-status", route["process_status"]),
                _prop("lca1:package:family", f"{physical['family']}{physical['pin_count']}"),
                _prop("lca1:package:status", package["package_status"]),
                _prop("lca1:submission:format", route["required_submission"]["format"]),
                _prop("lca1:source", RELEASE_JSON.as_posix()),
                _prop("lca1:source", PACKAGE_CONTRACT_JSON.as_posix()),
            ],
        )
    )

    components.append(
        component(
            f"hardware/harness/openframe@{shell['commit']}",
            "framework",
            shell["name"],
            group="chipfoundry",
            version=shell["commit"],
            description="OpenFrame user-project harness the Rev-A user area plugs into",
            noassertion_reason=(
                "upstream openframe_user_project terms are not inventoried in "
                "NOTICE; the repository vendors no OpenFrame source"
            ),
            purl=f"pkg:github/chipfoundry/openframe_user_project@{shell['commit']}",
            external_references=[
                _reference("vcs", shell["repository"]),
                _reference("documentation", package["source_shell"]["datasheet"]),
            ],
            properties=[
                _prop("lca1:hardware:kind", "soc-harness"),
                _prop("lca1:harness:top-module", shell["top_module"]),
                _prop("lca1:harness:template-tree", shell["template_tree"]),
                _prop("lca1:harness:user-area-mm2", shell["user_area_mm2"]),
                _prop("lca1:harness:gpio-count", shell["gpio_count"]),
                _prop("lca1:harness:freeze-status", shell["freeze_status"]),
                _prop("lca1:source", RELEASE_JSON.as_posix()),
            ],
        )
    )

    components.append(
        component(
            f"hardware/pdk/{harden['PDK']}",
            "library",
            harden["PDK"],
            description=f"{route['process']} process design kit variant used by the hardening flow",
            noassertion_reason=(
                "the repository vendors no PDK files and declares no PDK "
                "license; SKY130 terms come with the PDK, which is downloaded "
                "at flow time"
            ),
            properties=[
                _prop("lca1:hardware:kind", "pdk"),
                _prop("lca1:pdk:version-pin", "none: resolved by the LibreLane container at run time"),
                _prop("lca1:process", route["process"]),
                _prop("lca1:process-status", route["process_status"]),
                _prop("lca1:source", HARDEN_CONFIG.as_posix()),
            ],
        )
    )

    components.append(
        component(
            f"hardware/stdcells/{harden['STD_CELL_LIBRARY']}",
            "library",
            harden["STD_CELL_LIBRARY"],
            description="Standard cell library selected for the SKY130 hardening flow",
            noassertion_reason=(
                "the repository vendors no cell views and declares no cell "
                "library license; terms ship with the PDK"
            ),
            properties=[
                _prop("lca1:hardware:kind", "standard-cell-library"),
                _prop("lca1:pdk", harden["PDK"]),
                _prop("lca1:source", HARDEN_CONFIG.as_posix()),
            ],
        )
    )

    components.append(
        component(
            f"hardware/macro/{baseline['macro']}",
            "library",
            baseline["macro"],
            group="chipfoundry",
            description="Compiled SRAM macro selected for the Rev-A memory baseline",
            noassertion_reason=(
                f"commercial IP: {baseline['status']}"
            ),
            properties=[
                _prop("lca1:hardware:kind", "sram-macro"),
                _prop("lca1:macro:words-per-instance", baseline["words_per_instance"]),
                _prop("lca1:macro:bits-per-word", baseline["bits_per_word"]),
                _prop("lca1:macro:interface", baseline["interface"]),
                _prop("lca1:macro:area-mm2-each-vendor-published", baseline["area_mm2_each_vendor_published"]),
                _prop("lca1:memory:baseline-instances", baseline["instances"]),
                _prop("lca1:memory:baseline-bytes", baseline["logical_capacity_bytes"]),
                _prop("lca1:memory:experiment-instances", experiment["instances"]),
                _prop("lca1:memory:experiment-bytes", experiment["logical_capacity_bytes"]),
                _prop("lca1:macro:acquisition-status", baseline["status"]),
                _prop("lca1:source", RELEASE_JSON.as_posix()),
            ],
        )
    )
    return components


def collect_notice_files(root: Path) -> list[dict[str, Any]]:
    """Derived third-party files that NOTICE inventories, with content hashes."""
    components: list[dict[str, Any]] = []
    for relative, spdx_id, description in NOTICE_FILES:
        path = root / relative
        if not path.is_file():
            continue
        components.append(
            component(
                f"file/{relative}",
                "file",
                relative,
                licenses=_spdx(spdx_id),
                description=description,
                hashes=[{"alg": "SHA-256", "content": _sha256_file(path)}],
                properties=[
                    _prop("lca1:license:source", NOTICE.as_posix()),
                    _prop("lca1:role", "third-party-derived-source"),
                ],
            )
        )
    return components


def _workflow_texts(root: Path) -> list[tuple[str, str]]:
    directory = root / WORKFLOW_DIR
    if not directory.is_dir():
        return []
    return [
        (path.name, path.read_text(encoding="utf-8"))
        for path in sorted(directory.glob("*.yml")) + sorted(directory.glob("*.yaml"))
    ]


def scan_workflows(root: Path) -> dict[str, Any]:
    """Extract every pinned and unpinned supply-chain input from CI workflows."""
    actions: dict[tuple[str, str], dict[str, Any]] = {}
    unpinned: set[str] = set()
    repo_refs: dict[tuple[str, str], set[str]] = {}
    containers: dict[str, set[str]] = {}
    pip: dict[tuple[str, str], set[str]] = {}
    apt: dict[str, set[str]] = {}
    python_versions: set[str] = set()

    for filename, text in _workflow_texts(root):
        lines = text.splitlines()
        for match in _USES_RE.finditer(text):
            key = (match.group(1), match.group(2))
            record = actions.setdefault(
                key, {"version": match.group(3), "files": set()}
            )
            record["files"].add(filename)
        for match in _USES_ANY_RE.finditer(text):
            if "@" not in match.group(1) or not _SHA1_RE.match(match.group(1).split("@", 1)[1]):
                unpinned.add(match.group(1))
        for index, line in enumerate(lines):
            repo_match = _REPOSITORY_RE.match(line)
            if repo_match:
                for follower in lines[index + 1 : index + 5]:
                    ref_match = _REF_RE.match(follower)
                    if ref_match:
                        repo_refs.setdefault(
                            (repo_match.group(1), ref_match.group(1)), set()
                        ).add(filename)
                        break
        for match in _CONTAINER_RE.finditer(text):
            containers.setdefault(match.group(1), set()).add(filename)
        for match in _PIP_RE.finditer(text):
            pip.setdefault((match.group(1), match.group(2)), set()).add(filename)
        for match in _APT_RE.finditer(text):
            for token in match.group(1).split():
                if not token.startswith("-"):
                    apt.setdefault(token, set()).add(filename)
        python_versions.update(_PYVER_RE.findall(text))

    return {
        "actions": actions,
        "unpinned": unpinned,
        "repo_refs": repo_refs,
        "containers": containers,
        "pip": pip,
        "apt": apt,
        "python_versions": python_versions,
    }


def collect_actions(scan: dict[str, Any]) -> list[dict[str, Any]]:
    """GitHub Actions, each pinned to a full commit SHA in the workflows."""
    components: list[dict[str, Any]] = []
    for (slug, sha), record in sorted(scan["actions"].items()):
        owner, _, name = slug.partition("/")
        components.append(
            component(
                f"action/{slug}@{sha}",
                "application",
                name,
                group=owner,
                version=sha,
                description=f"GitHub Action pinned to a commit SHA ({record['version']})",
                noassertion_reason=(
                    "action licenses are not inventoried in NOTICE; the action "
                    "is executed by GitHub, not redistributed here"
                ),
                purl=f"pkg:github/{slug}@{sha}",
                external_references=[_reference("vcs", f"https://github.com/{slug}")],
                properties=[
                    _prop("lca1:action:release-tag", record["version"]),
                    _prop("lca1:action:pinned-by", "full commit SHA"),
                    _prop("lca1:role", "ci-action"),
                ]
                + [
                    _prop("lca1:source", f"{WORKFLOW_DIR.as_posix()}/{workflow}")
                    for workflow in sorted(record["files"])
                ],
            )
        )
    return components


def collect_toolchain(root: Path, scan: dict[str, Any]) -> list[dict[str, Any]]:
    """Node, npm, Python, simulators, the mutation tool, and the PnR container."""
    package = _read_json(root, PACKAGE_JSON)
    engines = package.get("engines", {})
    components: list[dict[str, Any]] = []

    for name, version in sorted(engines.items()):
        components.append(
            component(
                f"toolchain/{name}@{version}",
                "application",
                name,
                version=version,
                description="Build/verification runtime pinned by package.json engines",
                noassertion_reason=(
                    "host runtime is installed by CI, not redistributed here, "
                    "and its license is not declared in this repository"
                ),
                properties=[
                    _prop("lca1:role", "toolchain:runtime"),
                    _prop("lca1:source", PACKAGE_JSON.as_posix()),
                ],
            )
        )

    for version in sorted(scan["python_versions"]):
        components.append(
            component(
                f"toolchain/python@{version}",
                "application",
                "python",
                version=version,
                description="CPython interpreter pinned by the CI workflows",
                noassertion_reason=(
                    "interpreter is installed by CI and its license is not "
                    "declared in this repository"
                ),
                properties=[
                    _prop("lca1:role", "toolchain:runtime"),
                    _prop("lca1:python:requires-python", ">=3.10"),
                    _prop("lca1:source", f"{WORKFLOW_DIR.as_posix()}/ci.yml"),
                ],
            )
        )

    for name, sources in sorted(scan["apt"].items()):
        components.append(
            component(
                f"toolchain/apt/{name}",
                "application",
                name,
                description="Host tool installed unpinned from the Ubuntu runner archive",
                noassertion_reason=(
                    "distribution package: neither version nor license is "
                    "pinned by this repository"
                ),
                properties=[
                    _prop("lca1:role", "toolchain:host-tool"),
                    _prop("lca1:pin:gap", "apt-get install without a version pin"),
                    _prop(
                        "lca1:pin:mitigation",
                        "the resolved version is recorded per run into reports/",
                    ),
                ]
                + [_prop("lca1:source", f"{WORKFLOW_DIR.as_posix()}/{item}") for item in sorted(sources)],
            )
        )

    for (name, version), sources in sorted(scan["pip"].items()):
        components.append(
            component(
                f"pypi/{name}@{version}",
                "library",
                name,
                version=version,
                description="Python tool pinned to an exact version by the CI workflows",
                noassertion_reason="license is not declared in this repository",
                purl=f"pkg:pypi/{name}@{version}",
                properties=[
                    _prop("lca1:role", "toolchain:ci"),
                    _prop("lca1:pin:kind", "exact version, no hash"),
                ]
                + [_prop("lca1:source", f"{WORKFLOW_DIR.as_posix()}/{item}") for item in sorted(sources)],
            )
        )

    for (slug, sha), sources in sorted(scan["repo_refs"].items()):
        owner, _, name = slug.partition("/")
        components.append(
            component(
                f"repo/{slug}@{sha}",
                "application",
                name,
                group=owner,
                version=sha,
                description="External repository checked out in CI, pinned to a commit SHA",
                noassertion_reason="license is not inventoried in NOTICE",
                purl=f"pkg:github/{slug}@{sha}",
                external_references=[_reference("vcs", f"https://github.com/{slug}")],
                properties=[
                    _prop("lca1:role", "toolchain:ci"),
                    _prop("lca1:pin:kind", "full commit SHA"),
                ]
                + [_prop("lca1:source", f"{WORKFLOW_DIR.as_posix()}/{item}") for item in sorted(sources)],
            )
        )

    for image, sources in sorted(scan["containers"].items()):
        repository, _, tag = image.rpartition(":")
        components.append(
            component(
                f"container/{image}",
                "container",
                repository,
                version=tag,
                description="Container image used by the physical-implementation flow",
                noassertion_reason="image license is not declared in this repository",
                external_references=[_reference("distribution", f"https://{repository}")],
                properties=[
                    _prop("lca1:role", "toolchain:physical-implementation"),
                    _prop("lca1:container:reference", image),
                    _prop("lca1:container:digest", "NOASSERTION"),
                    _prop(
                        "lca1:pin:gap",
                        "pinned by mutable version tag, not by immutable "
                        "sha256 digest; a retag would change the tool without "
                        "changing this SBOM",
                    ),
                ]
                + [_prop("lca1:source", f"{WORKFLOW_DIR.as_posix()}/{item}") for item in sorted(sources)],
            )
        )
    return components


# --------------------------------------------------------------------------
# document assembly
# --------------------------------------------------------------------------


def _compositions(components: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    refs = {entry["bom-ref"] for entry in components}

    def matching(prefix: str) -> list[str]:
        return sorted(ref for ref in refs if ref.startswith(prefix))

    groups: list[tuple[str, list[str]]] = [
        ("complete", matching("npm/")),
        ("incomplete", matching("submodule/")),
        ("incomplete", matching("hardware/") + matching("container/")),
        ("incomplete_first_party_only", matching("file/") + matching("lca1@")),
        ("complete", matching("action/") + matching("repo/")),
        ("unknown", matching("toolchain/apt/")),
    ]
    compositions: list[dict[str, Any]] = []
    for aggregate, assemblies in groups:
        if assemblies:
            compositions.append({"aggregate": aggregate, "assemblies": sorted(assemblies)})
    return compositions


def build_bom(root: Path) -> dict[str, Any]:
    scan = scan_workflows(root)
    root_component, build_requirements = collect_python(root)

    components: list[dict[str, Any]] = []
    components += collect_npm(root)
    components += build_requirements
    components += collect_submodules(root)
    components += collect_notice_files(root)
    components += collect_hardware(root)
    components += collect_toolchain(root, scan)
    components += collect_actions(scan)
    components.sort(key=lambda entry: entry["bom-ref"])

    duplicates = {
        ref
        for ref in (entry["bom-ref"] for entry in components)
        if [entry["bom-ref"] for entry in components].count(ref) > 1
    }
    if duplicates:
        raise ValueError(f"duplicate bom-ref values: {sorted(duplicates)}")

    metadata_properties = [
        _prop("SPDX-License-Identifier", "Apache-2.0"),
        _prop("lca1:sbom:generator", GENERATOR_NAME),
        _prop("lca1:sbom:generator-version", GENERATOR_VERSION),
        _prop("lca1:sbom:determinism", "sorted keys, no wall-clock timestamp, repo-only inputs"),
        _prop(
            "lca1:sbom:timestamp-omitted",
            "metadata.timestamp is intentionally absent so --check is a real "
            "drift gate; build time is recorded by the workflow run instead",
        ),
        _prop(
            "lca1:sbom:commit-omitted",
            "the repository commit is intentionally absent (a committed file "
            "cannot contain its own commit hash); it is bound by the workflow "
            "artifact name and the SLSA provenance attestation",
        ),
        _prop("lca1:sbom:component-count", len(components)),
        _prop("lca1:sbom:regenerate", "python3 tools/gen_sbom.py --output docs/sbom.cdx.json"),
        _prop("lca1:sbom:verify", "python3 tools/gen_sbom.py --check"),
    ]
    for reference in sorted(scan["unpinned"]):
        metadata_properties.append(_prop("lca1:ci:unpinned-action", reference))

    bom: dict[str, Any] = {
        "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": SPEC_VERSION,
        "serialNumber": "urn:uuid:"
        + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{REPO_URL}#cyclonedx-sbom")),
        "version": BOM_VERSION,
        "metadata": {
            "authors": [{"name": AUTHOR}],
            "supplier": {"name": SUPPLIER, "url": [REPO_URL]},
            "component": root_component,
            "licenses": _spdx("Apache-2.0"),
            "tools": {
                "components": [
                    component(
                        f"tool/{GENERATOR_NAME}@{GENERATOR_VERSION}",
                        "application",
                        GENERATOR_NAME,
                        version=GENERATOR_VERSION,
                        description="Dependency-free CycloneDX generator in this repository",
                        licenses=_spdx("Apache-2.0"),
                    )
                ]
            },
            "properties": metadata_properties,
        },
        "components": components,
        "dependencies": [
            {
                "ref": root_component["bom-ref"],
                "dependsOn": sorted(entry["bom-ref"] for entry in components),
            }
        ]
        + [{"ref": entry["bom-ref"], "dependsOn": []} for entry in components],
        "compositions": _compositions(components),
    }
    return bom


def render(bom: dict[str, Any]) -> str:
    return json.dumps(bom, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _digest(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the committed SBOM is missing or differs",
    )
    args = parser.parse_args(argv)

    content = render(build_bom(args.repo_root.resolve()))
    output = args.output.resolve()
    count = len(json.loads(content)["components"])

    if args.check:
        if not output.exists():
            print(f"ERROR missing generated SBOM: {output}", file=sys.stderr)
            return 1
        actual = output.read_text(encoding="utf-8")
        if actual != content:
            print(
                "ERROR generated SBOM drift: "
                f"expected sha256={_digest(content)} actual sha256={_digest(actual)}\n"
                "      regenerate with: python3 tools/gen_sbom.py "
                f"--output {args.output}",
                file=sys.stderr,
            )
            return 1
        print(
            f"PASS SBOM: CycloneDX {SPEC_VERSION}, {count} components, "
            f"sha256={_digest(content)}"
        )
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")
    print(
        f"WROTE {output}: CycloneDX {SPEC_VERSION}, {count} components, "
        f"sha256={_digest(content)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
