# SPDX-License-Identifier: Apache-2.0
"""Validate the generated CycloneDX supply-chain SBOM.

These tests are about honesty as much as schema shape: every component must
make an explicit licensing decision, every recorded pin must be a real full
commit SHA, and the generator must be a pure function of the repository so a
third party can re-derive the same bytes.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
import unittest
from pathlib import Path

from tools.gen_sbom import (
    DEFAULT_OUTPUT,
    NOASSERTION_REASON,
    SPEC_VERSION,
    build_bom,
    parse_gitmodules,
    render,
)

ROOT = Path(__file__).resolve().parents[1]

FULL_SHA = re.compile(r"^[0-9a-f]{40}$")

# CycloneDX 1.6 component classification enum.
COMPONENT_TYPES = {
    "application",
    "framework",
    "library",
    "container",
    "platform",
    "operating-system",
    "device",
    "device-driver",
    "firmware",
    "file",
    "machine-learning-model",
    "data",
    "cryptographic-asset",
}


class SbomDocumentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rendered = render(build_bom(ROOT))
        cls.bom = json.loads(cls.rendered)
        cls.components = cls.bom["components"]

    # -- required CycloneDX structure ------------------------------------

    def test_required_top_level_fields(self) -> None:
        self.assertEqual(self.bom["bomFormat"], "CycloneDX")
        self.assertEqual(self.bom["specVersion"], SPEC_VERSION)
        self.assertIsInstance(self.bom["version"], int)
        self.assertRegex(
            self.bom["serialNumber"],
            r"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        )
        self.assertEqual(
            self.bom["$schema"], "http://cyclonedx.org/schema/bom-1.6.schema.json"
        )

    def test_metadata_declares_the_first_party_component_and_generator(self) -> None:
        metadata = self.bom["metadata"]
        root = metadata["component"]
        self.assertEqual(root["name"], "lca1")
        self.assertEqual(root["type"], "application")
        self.assertEqual(
            [entry["license"]["id"] for entry in root["licenses"]], ["Apache-2.0"]
        )
        tools = metadata["tools"]["components"]
        self.assertEqual([tool["name"] for tool in tools], ["tools/gen_sbom.py"])

    def test_components_carry_required_fields(self) -> None:
        self.assertGreater(len(self.components), 20)
        seen: set[str] = set()
        for entry in self.components:
            with self.subTest(component=entry.get("bom-ref")):
                self.assertIn("bom-ref", entry)
                self.assertNotIn(entry["bom-ref"], seen)
                seen.add(entry["bom-ref"])
                self.assertIn(entry["type"], COMPONENT_TYPES)
                self.assertTrue(entry["name"])

    def test_dependency_graph_resolves(self) -> None:
        refs = {entry["bom-ref"] for entry in self.components}
        refs.add(self.bom["metadata"]["component"]["bom-ref"])
        for edge in self.bom["dependencies"]:
            self.assertIn(edge["ref"], refs)
            for dependency in edge["dependsOn"]:
                self.assertIn(dependency, refs)
        root_edge = next(
            edge
            for edge in self.bom["dependencies"]
            if edge["ref"] == self.bom["metadata"]["component"]["bom-ref"]
        )
        self.assertEqual(len(root_edge["dependsOn"]), len(self.components))

    def test_compositions_declare_coverage_honestly(self) -> None:
        aggregates = {entry["aggregate"] for entry in self.bom["compositions"]}
        self.assertIn("incomplete", aggregates)
        covered = {
            ref
            for entry in self.bom["compositions"]
            for ref in entry["assemblies"]
        }
        submodules = {
            entry["bom-ref"]
            for entry in self.components
            if entry["bom-ref"].startswith("submodule/")
        }
        self.assertTrue(submodules)
        self.assertTrue(submodules <= covered)

    # -- licensing honesty ------------------------------------------------

    def test_every_component_states_a_license_or_an_explained_noassertion(self) -> None:
        for entry in self.components + [self.bom["metadata"]["component"]]:
            with self.subTest(component=entry["bom-ref"]):
                licenses = entry.get("licenses")
                self.assertTrue(licenses, "component declares no licenses array")
                names = [
                    item["license"].get("id") or item["license"].get("name")
                    for item in licenses
                ]
                self.assertTrue(all(names))
                if "NOASSERTION" in names:
                    self.assertEqual(
                        names,
                        ["NOASSERTION"],
                        "NOASSERTION must not be mixed with concrete licenses",
                    )
                    reasons = [
                        prop["value"]
                        for prop in entry.get("properties", [])
                        if prop["name"] == NOASSERTION_REASON
                    ]
                    self.assertEqual(len(reasons), 1)
                    self.assertGreater(len(reasons[0]), 10)

    def test_declared_licenses_match_the_repository_inventory(self) -> None:
        by_ref = {entry["bom-ref"]: entry for entry in self.components}

        def ids(ref: str) -> list[str]:
            return [item["license"]["id"] for item in by_ref[ref]["licenses"]]

        picorv32 = next(
            ref for ref in by_ref if ref.startswith("submodule/third_party/picorv32")
        )
        pqclean = next(
            ref for ref in by_ref if ref.startswith("submodule/third_party/PQClean")
        )
        self.assertEqual(ids(picorv32), ["ISC"])
        self.assertEqual(sorted(ids(pqclean)), ["Apache-2.0", "CC0-1.0", "MIT"])
        self.assertEqual(ids("npm/@yowasp/yosys@0.68.1207"), ["ISC"])
        for ref in by_ref:
            if ref.startswith("file/"):
                self.assertEqual(ids(ref), ["CC0-1.0"])

    # -- pins --------------------------------------------------------------

    def test_submodule_shas_are_full_forty_character_hashes(self) -> None:
        submodules = [
            entry
            for entry in self.components
            if entry["bom-ref"].startswith("submodule/")
        ]
        self.assertEqual(len(submodules), 2)
        for entry in submodules:
            with self.subTest(component=entry["bom-ref"]):
                properties = {
                    prop["name"]: prop["value"] for prop in entry["properties"]
                }
                source = properties["lca1:submodule:sha-source"]
                if source == "unavailable":
                    self.assertEqual(entry["version"], "NOASSERTION")
                    continue
                self.assertRegex(entry["version"], FULL_SHA)
                self.assertTrue(entry["purl"].endswith("@" + entry["version"]))
                self.assertIn(
                    properties["lca1:submodule:checked-out"],
                    {"true", "false", "unknown"},
                )

    def test_uncheckedout_submodules_are_recorded_as_a_gap(self) -> None:
        for entry in self.components:
            if not entry["bom-ref"].startswith("submodule/"):
                continue
            properties = [
                (prop["name"], prop["value"]) for prop in entry["properties"]
            ]
            checked_out = dict(properties)["lca1:submodule:checked-out"]
            gaps = [value for name, value in properties if name == "lca1:submodule:gap"]
            if checked_out == "false":
                self.assertTrue(
                    any("working tree not populated" in gap for gap in gaps),
                    "an unpopulated submodule must record the coverage gap",
                )

    def test_github_actions_are_pinned_to_full_commit_shas(self) -> None:
        actions = [
            entry for entry in self.components if entry["bom-ref"].startswith("action/")
        ]
        self.assertTrue(actions)
        for entry in actions:
            with self.subTest(component=entry["bom-ref"]):
                self.assertRegex(entry["version"], FULL_SHA)
                properties = {
                    prop["name"]: prop["value"] for prop in entry["properties"]
                }
                self.assertRegex(properties["lca1:action:release-tag"], r"^v\d")

    def test_no_unpinned_actions_are_reported(self) -> None:
        unpinned = [
            prop["value"]
            for prop in self.bom["metadata"]["properties"]
            if prop["name"] == "lca1:ci:unpinned-action"
        ]
        self.assertEqual(unpinned, [], f"unpinned GitHub Actions in CI: {unpinned}")

    def test_npm_integrity_is_recorded_as_a_decoded_hash(self) -> None:
        entry = next(
            item
            for item in self.components
            if item["bom-ref"].startswith("npm/@yowasp/yosys")
        )
        properties = {prop["name"]: prop["value"] for prop in entry["properties"]}
        integrity = properties["lca1:npm:integrity"]
        algorithm, _, encoded = integrity.partition("-")
        expected = binascii.hexlify(base64.b64decode(encoded, validate=True)).decode()
        hashes = {item["alg"]: item["content"] for item in entry["hashes"]}
        self.assertEqual(algorithm, "sha512")
        self.assertEqual(hashes["SHA-512"], expected)

    def test_hardware_and_toolchain_layers_are_covered(self) -> None:
        prefixes = {
            "npm/": "npm dependency",
            "submodule/": "git submodule",
            "hardware/pdk/": "process design kit",
            "hardware/stdcells/": "standard cell library",
            "hardware/macro/": "SRAM macro",
            "hardware/harness/": "OpenFrame harness",
            "hardware/device/": "Rev-A device contract",
            "container/": "physical-implementation container",
            "toolchain/": "build toolchain",
            "action/": "CI action",
            "file/": "third-party derived file",
        }
        refs = [entry["bom-ref"] for entry in self.components]
        for prefix, label in prefixes.items():
            with self.subTest(layer=label):
                self.assertTrue(
                    any(ref.startswith(prefix) for ref in refs),
                    f"SBOM covers no {label}",
                )

    # -- determinism -------------------------------------------------------

    def test_generator_is_deterministic(self) -> None:
        self.assertEqual(render(build_bom(ROOT)), render(build_bom(ROOT)))

    def test_document_carries_no_wall_clock_timestamp(self) -> None:
        def keys(node: object) -> list[str]:
            if isinstance(node, dict):
                return [
                    key
                    for name, value in node.items()
                    for key in [name] + keys(value)
                ]
            if isinstance(node, list):
                return [key for item in node for key in keys(item)]
            return []

        self.assertNotIn("timestamp", keys(self.bom))
        self.assertIn(
            "lca1:sbom:timestamp-omitted",
            [prop["name"] for prop in self.bom["metadata"]["properties"]],
            "the omission must be stated in the document, not just implied",
        )

    def test_keys_are_sorted_for_stable_diffs(self) -> None:
        self.assertEqual(
            self.rendered,
            json.dumps(self.bom, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        )

    def test_committed_sbom_matches_the_generator(self) -> None:
        committed = DEFAULT_OUTPUT
        self.assertTrue(
            committed.is_file(), f"missing committed SBOM: {committed}"
        )
        self.assertEqual(
            committed.read_text(encoding="utf-8"),
            self.rendered,
            "docs/sbom.cdx.json is stale; run "
            "python3 tools/gen_sbom.py --output docs/sbom.cdx.json",
        )


class GitmodulesParserTests(unittest.TestCase):
    def test_parses_tab_indented_entries(self) -> None:
        parsed = parse_gitmodules(
            '[submodule "third_party/example"]\n'
            "\tpath = third_party/example\n"
            "\turl = https://example.invalid/example.git\n"
        )
        self.assertEqual(
            parsed,
            [
                {
                    "name": "third_party/example",
                    "path": "third_party/example",
                    "url": "https://example.invalid/example.git",
                }
            ],
        )

    def test_matches_the_committed_gitmodules(self) -> None:
        parsed = parse_gitmodules(
            (ROOT / ".gitmodules").read_text(encoding="utf-8")
        )
        self.assertEqual(
            sorted(module["path"] for module in parsed),
            ["third_party/PQClean", "third_party/picorv32"],
        )


if __name__ == "__main__":
    unittest.main()
