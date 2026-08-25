#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Stage the pinned OpenFrame project with LCA-1 Rev-A hardening targets.

The script creates a disposable hardening workspace. It never mutates the
source checkout and never follows floating Git refs. SRAM22 views are fetched
through tools/fetch_sram22_macros.py, which verifies every file by Git blob ID.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN = ROOT / "physical" / "openframe" / "toolchain.json"
OPENLANE_OVERLAY = ROOT / "physical" / "openframe" / "openlane"
SRAM_VENDOR = ROOT / "physical" / "sram22" / "vendor"


def run(*args: str, cwd: Path | None = None) -> None:
    print("+", " ".join(args))
    subprocess.run(args, cwd=cwd, check=True)


def copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def clone_exact(url: str, commit: str, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    run("git", "init", str(dst))
    run("git", "remote", "add", "origin", url, cwd=dst)
    run("git", "fetch", "--depth=1", "origin", commit, cwd=dst)
    run("git", "checkout", "--detach", "FETCH_HEAD", cwd=dst)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=dst, text=True).strip()
    if actual != commit:
        raise RuntimeError(f"OpenFrame commit mismatch: expected {commit}, got {actual}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=ROOT / "build" / "openframe")
    parser.add_argument("--no-network", action="store_true", help="require an already-fetched SRAM22 vendor tree")
    args = parser.parse_args()

    toolchain = json.loads(TOOLCHAIN.read_text())
    workspace = args.workspace.resolve()
    source = toolchain["openframe"]
    clone_exact(source["repository"], source["commit"], workspace)

    if args.no_network:
        run(sys.executable, str(ROOT / "tools" / "fetch_sram22_macros.py"), "--check")
    else:
        run(sys.executable, str(ROOT / "tools" / "fetch_sram22_macros.py"))

    rtl_dst = workspace / "verilog" / "rtl" / "lca"
    for name in (
        "lca_sram22_macros.sv",
        "lca_ntt_accel_sram22.sv",
        "lca_ntt_zetas.svh",
        "lca_secure_sram_sram22.sv",
    ):
        copy(ROOT / "rtl" / name, rtl_dst / name)

    vendor_verilog = workspace / "verilog" / "rtl" / "lca_vendor"
    lef_dst = workspace / "lef" / "lca"
    gds_dst = workspace / "gds" / "lca"
    lib_dst = workspace / "lib" / "lca"

    macro_names = ("sram22_128x32m4w8", "sram22_2048x32m8w8")
    staged_files: list[Path] = []
    for macro in macro_names:
        base = SRAM_VENDOR / macro
        for suffix, target_dir in ((".v", vendor_verilog), (".lef", lef_dst)):
            src = base / f"{macro}{suffix}"
            dst = target_dir / src.name
            copy(src, dst)
            staged_files.append(dst)

        gds_gz = base / f"{macro}.gds.gz"
        gds = gds_dst / f"{macro}.gds"
        gds.parent.mkdir(parents=True, exist_ok=True)
        with gzip.open(gds_gz, "rb") as source_stream, gds.open("wb") as dest_stream:
            shutil.copyfileobj(source_stream, dest_stream)
        staged_files.append(gds)

        for corner in ("tt_025C_1v80", "ss_100C_1v60", "ff_n40C_1v95"):
            src = base / f"{macro}_{corner}.lib"
            dst = lib_dst / src.name
            copy(src, dst)
            staged_files.append(dst)

    for config_dir in OPENLANE_OVERLAY.iterdir():
        if config_dir.is_dir():
            target = workspace / "openlane" / config_dir.name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(config_dir, target)

    evidence = {
        "openframe_commit": source["commit"],
        "chipfoundry_librelane_tag": toolchain["librelane"]["chipfoundry_tag"],
        "pdk": toolchain["pdk"],
        "clock": toolchain["clock"],
        "staged_sha256": {
            path.relative_to(workspace).as_posix(): sha256(path)
            for path in sorted(staged_files)
        },
    }
    evidence_path = workspace / "lca1-physical-stage.json"
    evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(f"PASS staged pinned OpenFrame physical workspace: {workspace}")
    print(f"Evidence: {evidence_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
