#!/usr/bin/env python3
"""Unit/counterexample tests for occurrence-aware full-byte release secret scanning."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci"))

import release_fullbyte_secret_scan as scan  # noqa: E402


ALG = b"sk-ecdsa-sha2-nistp256-cert-v01"
RSA = b"-----BEGIN RSA PRIVATE KEY-----"
EC = b"-----BEGIN EC PRIVATE KEY-----"
OPENSSH = b"-----BEGIN OPENSSH PRIVATE KEY-----"
PKCS8 = b"-----BEGIN PRIVATE KEY-----"

# Synthetic non-credential shaped fixtures (never real secrets).
GHP = b"ghp_" + (b"A" * 36)
GHO = b"gho_" + (b"B" * 36)
GHU = b"ghu_" + (b"C" * 36)
GHS = b"ghs_" + (b"D" * 36)
GH_PAT = b"github_pat_" + (b"E" * 22) + b"_" + (b"F" * 59)
AKIA = b"AKIA" + (b"G" * 16)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().lower()


def _write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _mini_policy(exceptions: list, **extra) -> dict:
    base = {
        "status": "ACTIVE_TEST",
        "policyId": "unit-test-policy",
        "authorCard": "s63i-hf2b",
        "occurrenceCount": len(exceptions),
        "providerFamilies": list(scan.PROVIDER_FAMILY_IDS),
        "exceptions": exceptions,
        "explicitlyNotAllowed": [
            "filename_allowlist",
            "library_allowlist",
            "global_pattern_allowlist",
            "backend_companion_snakeoil_complete_pem",
            "empty_gitleaks_array_as_gate_pass",
            "git_directory_skip",
            "status_string_packaging_authorization",
            "overwrite_existing_scan_output",
        ],
        "limitations": {
            "ffmpegUnsignedDistributorProvenance": "NOT_PROVEN",
            "note": "unit test limitation note",
        },
        "gitleaks": {"independent": True, "note": "empty [] not enough"},
        "evidenceBinding": {"requireExactProposedMatch": False},
        "expectedReleaseTree": {"requireBinding": False},
    }
    base.update(extra)
    return base


def _ex(
    relative_path: str,
    data: bytes,
    rule: str,
    offset: int,
    matched: bytes,
    classification: str = "TEST_PUBLIC_CONSTANT",
) -> dict:
    return {
        "active": True,
        "relativePath": relative_path,
        "fileBytes": len(data),
        "fileSHA256": _sha(data),
        "rule": rule,
        "offsetBasis": "ZERO_BASED_FILE_BYTE_OFFSET",
        "offset": offset,
        "length": len(matched),
        "matchedBytesSHA256": _sha(matched),
        "classification": classification,
        "publicSourceProof": [
            {
                "sourceFile": "unit-test/source.c",
                "rule": rule,
                "line": 1,
                "length": len(matched),
                "matchedBytesSHA256": _sha(matched),
            }
        ],
    }


def _tree_manifest(root: Path) -> dict:
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            rel = path.relative_to(root).as_posix()
            data = path.read_bytes()
            files.append(
                {
                    "relativePath": rel,
                    "sizeBytes": len(data),
                    "sha256": _sha(data),
                }
            )
    return {"files": files}


class FullByteScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fullbyte-scan-"))
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))

    def _scan(self, policy: dict, tree: Path, **kwargs) -> dict:
        raw = (json.dumps(policy, indent=2) + "\n").encode("utf-8")
        policy_path = self.tmp / ("policy-" + _sha(raw)[:12] + ".json")
        policy_path.write_bytes(raw)
        loaded = scan.load_policy(policy_path)
        return scan.scan_tree(tree, loaded, **kwargs)

    def test_public_constant_digests_match_review(self) -> None:
        self.assertEqual(
            _sha(ALG),
            "3ba30ddc57c5e012f28276fa224e3485067a139cd220da03b730060afb01b2b9",
        )
        self.assertEqual(
            _sha(RSA),
            "8bcac7908eb950419537b91e19adc83ce2c9cbfdacf4f81157fdadfec11f7017",
        )

    def test_provider_family_coverage_detects_all_prior_families(self) -> None:
        fixtures = {
            "sk": ALG,
            "ghp": GHP,
            "gho": GHO,
            "ghu": GHU,
            "ghs": GHS,
            "github_pat": GH_PAT,
            "akia": AKIA,
        }
        for family, blob in fixtures.items():
            occs = scan.find_occurrences(f"{family}.bin", blob)
            self.assertEqual(len(occs), 1, family)
            self.assertEqual(occs[0].rule, scan.RULE_PROVIDER)
            self.assertEqual(occs[0].provider_family, family)

    def test_missing_family_whole_tree_no_longer_false_pass(self) -> None:
        # Independent counterexample: excepted sk public constant + second file with
        # GitHub classic / fine-grained / AWS families must FAIL (not PASS).
        sk_blob = bytearray(b"\x00" * 64)
        sk_blob[8 : 8 + len(ALG)] = ALG
        sk_blob[8 + len(ALG) : 8 + len(ALG) + 12] = b"@openssh.com"
        sk_data = bytes(sk_blob)
        other = GHP + b"\n" + GH_PAT + b"\n" + AKIA
        tree = self.tmp / "tree-families"
        _write(tree / "ok.bin", sk_data)
        _write(tree / "legacy-families.bin", other)
        exceptions = [_ex("ok.bin", sk_data, scan.RULE_PROVIDER, 8, ALG)]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        families = {
            r.get("providerFamily")
            for r in report["remainingFindings"]
            if r.get("disposition") == scan.DISPOSITION_FINDING
        }
        self.assertTrue({"ghp", "github_pat", "akia"} <= families)

    def test_git_directory_is_scanned_not_skipped(self) -> None:
        sk_blob = bytearray(b"\x00" * 64)
        sk_blob[8 : 8 + len(ALG)] = ALG
        sk_data = bytes(sk_blob)
        tree = self.tmp / "tree-git"
        _write(tree / "ok.bin", sk_data)
        _write(tree / ".git" / "hidden.bin", b"sk-" + (b"Z" * 40))
        exceptions = [_ex("ok.bin", sk_data, scan.RULE_PROVIDER, 8, ALG)]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        self.assertGreaterEqual(report["filesScanned"], 2)
        self.assertTrue(
            any(
                r.get("relativePath") in {".git/hidden.bin", "git/hidden.bin"}
                or str(r.get("relativePath", "")).endswith(".git/hidden.bin")
                or str(r.get("relativePath", "")).endswith("git/hidden.bin")
                for r in report["remainingFindings"]
            ),
            report["remainingFindings"],
        )
        self.assertTrue(
            any(r.get("relativePath") == ".git/hidden.bin" for r in report["remainingFindings"]),
            "hidden .git path must retain leading dot after normalize_rel",
        )

    def test_symlink_file_rejected(self) -> None:
        tree = self.tmp / "tree-symlink"
        target = tree / "real.bin"
        _write(target, b"hello")
        link = tree / "link.bin"
        link.symlink_to(target)
        report = self._scan(_mini_policy([]), tree)
        self.assertFalse(report["ok"])
        self.assertEqual(report["status"], "FAIL_SCAN_ERROR")
        self.assertTrue(
            any("symlink" in str(r.get("problem", "")).lower() for r in report["remainingFindings"])
        )

    def test_symlink_directory_rejected(self) -> None:
        tree = self.tmp / "tree-symlink-dir"
        real = tree / "realdir"
        real.mkdir(parents=True)
        _write(real / "a.bin", b"hello")
        (tree / "alias").symlink_to(real, target_is_directory=True)
        report = self._scan(_mini_policy([]), tree)
        self.assertFalse(report["ok"])
        self.assertTrue(
            any("symlink" in str(r.get("problem", "")).lower() for r in report["remainingFindings"])
        )

    def test_unreadable_directory_fails_closed(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root can read mode-000 directories")
        tree = self.tmp / "tree-unreadable"
        hidden = tree / "locked"
        hidden.mkdir(parents=True)
        _write(hidden / "x.bin", b"sk-" + (b"Q" * 40))
        os.chmod(hidden, 0)
        try:
            report = self._scan(_mini_policy([]), tree)
            self.assertFalse(report["ok"])
            self.assertEqual(report["status"], "FAIL_SCAN_ERROR")
        finally:
            os.chmod(hidden, 0o755)

    def test_expected_file_count_and_manifest_binding(self) -> None:
        tree = self.tmp / "tree-manifest"
        _write(tree / "a.bin", b"hello")
        _write(tree / "b.bin", b"world")
        manifest = _tree_manifest(tree)
        report = self._scan(
            _mini_policy([]),
            tree,
            expected_file_count=2,
            tree_manifest={
                **manifest,
                "_manifestFileSha256": "X",
            },
        )
        self.assertTrue(report["ok"])
        bad = self._scan(_mini_policy([]), tree, expected_file_count=3)
        self.assertFalse(bad["ok"])
        self.assertEqual(bad["status"], "FAIL_MANIFEST_BINDING")

    def test_family_at_eof_chunk_boundary_and_large_file(self) -> None:
        chunk = 1024 * 1024
        # EOF
        eof = (b"\x00" * 100) + GHP
        self.assertEqual(len(scan.find_occurrences("eof.bin", eof)), 1)
        # Exact 1MiB boundary: token starts at chunk-8
        large = bytearray(b"\x00" * (chunk + 64))
        start = chunk - 8
        large[start : start + len(AKIA)] = AKIA
        occs = scan.find_occurrences("large.bin", bytes(large))
        self.assertEqual(len(occs), 1)
        self.assertEqual(occs[0].offset, start)
        # Appended after large payload
        appended = bytes(large) + b"\n" + GH_PAT
        self.assertEqual(len(scan.find_occurrences("appended.bin", appended)), 2)

    def test_appended_and_new_file_family_fail(self) -> None:
        data = bytearray(b"\x00" * 128)
        data[8 : 8 + len(ALG)] = ALG
        clean = bytes(data)
        tree = self.tmp / "tree-append-new"
        poisoned = clean + b"\n" + GHO
        _write(tree / "fixture.dll", poisoned)
        _write(tree / "new-file.bin", GHS)
        exceptions = [_ex("fixture.dll", clean, scan.RULE_PROVIDER, 8, ALG)]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        families = {
            r.get("providerFamily")
            for r in report["remainingFindings"]
            if r.get("disposition") == scan.DISPOSITION_FINDING
        }
        self.assertTrue({"gho", "ghs"} <= families)

    def test_exempted_nul_terminated_headers_and_algorithm_name(self) -> None:
        blob = bytearray(b"\x00" * 256)
        placements = [
            (10, ALG, scan.RULE_PROVIDER),
            (60, RSA, scan.RULE_PEM),
            (100, EC, scan.RULE_PEM),
            (140, OPENSSH, scan.RULE_PEM),
            (190, PKCS8, scan.RULE_PEM),
        ]
        for offset, matched, _rule in placements:
            blob[offset : offset + len(matched)] = matched
            if matched.startswith(b"-----"):
                if offset > 0:
                    blob[offset - 1] = 0
                blob[offset + len(matched)] = 0
        blob[10 + len(ALG) : 10 + len(ALG) + len(b"@openssh.com")] = b"@openssh.com"
        data = bytes(blob)
        rel = "fixture.dll"
        tree = self.tmp / "tree-ok"
        _write(tree / rel, data)
        exceptions = [
            _ex(rel, data, rule, offset, matched)
            for offset, matched, rule in placements
        ]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertTrue(report["ok"], report["remainingFindings"])
        dumped = json.dumps(report)
        self.assertNotIn("sk-ecdsa", dumped)
        self.assertNotIn("ghp_", dumped)

    def test_complete_pem_not_exempted(self) -> None:
        body = b"MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA"
        pem = RSA + b"\n" + body + b"\n-----END RSA PRIVATE KEY-----\n"
        rel = "snakeoil.pem"
        tree = self.tmp / "tree-pem"
        _write(tree / rel, pem)
        exceptions = [
            _ex(
                rel,
                pem,
                scan.RULE_PEM,
                0,
                RSA,
                classification="NUL_TERMINATED_RSA_PEM_HEADER_CONSTANT",
            )
        ]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        self.assertTrue(
            any(r["disposition"] == scan.DISPOSITION_COMPLETE_PEM for r in report["remainingFindings"])
        )

    def test_active_policy_matches_proposed_evidence(self) -> None:
        policy_path = ROOT / "manifests" / "security" / "release-fullbyte-scan-policy.s63i-hf2b.json"
        policy = scan.load_policy(policy_path)
        problems = scan.validate_policy_evidence(policy)
        self.assertEqual(problems, [], problems)
        self.assertEqual(len(policy["exceptions"]), 18)
        self.assertEqual(list(policy["providerFamilies"]), list(scan.PROVIDER_FAMILY_IDS))
        self.assertTrue(policy["evidenceBinding"]["requireExactProposedMatch"])
        self.assertTrue(policy["expectedReleaseTree"]["requireBinding"])

    def test_nonempty_but_wrong_proof_rejected(self) -> None:
        data = b"\x00" * 32 + ALG + b"\x00"
        ex = _ex("fixture.dll", data, scan.RULE_PROVIDER, 32, ALG)
        ex["publicSourceProof"][0]["matchedBytesSHA256"] = "0" * 64
        problems = scan.validate_policy_evidence(_mini_policy([ex]))
        self.assertTrue(any("matchedBytesSHA256 must equal exception digest" in p for p in problems))

    def test_exclusive_output_rejects_existing_and_protected(self) -> None:
        tree = self.tmp / "out-tree"
        tree.mkdir()
        _write(tree / "a.bin", b"hello")
        existing = self.tmp / "exists.json"
        existing.write_text("{}\n", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            scan.assert_safe_new_output(
                existing, release_root=tree, policy_path=ROOT / "manifests/security/release-fullbyte-scan-policy.s63i-hf2b.json"
            )
        inside = tree / "report.json"
        with self.assertRaises(ValueError):
            scan.assert_safe_new_output(
                inside, release_root=tree, policy_path=ROOT / "manifests/security/release-fullbyte-scan-policy.s63i-hf2b.json"
            )
        protected = self.tmp / "ORIGINAL-FAIL-RECEIPT.REFERENCE.json"
        with self.assertRaises(ValueError):
            scan.assert_safe_new_output(
                protected, release_root=tree, policy_path=ROOT / "manifests/security/release-fullbyte-scan-policy.s63i-hf2b.json"
            )

    def test_cli_create_new_preserves_existing_bytes(self) -> None:
        tree = self.tmp / "cli-tree"
        data = bytearray(b"\x00" * 64)
        data[4 : 4 + len(ALG)] = ALG
        blob = bytes(data)
        _write(tree / "a.dll", blob)
        policy = _mini_policy([_ex("a.dll", blob, scan.RULE_PROVIDER, 4, ALG)])
        policy_path = self.tmp / "cli-policy.json"
        policy_path.write_text(json.dumps(policy, indent=2) + "\n", encoding="utf-8")
        out = self.tmp / "audited-fullbyte-scan-report.json"
        prior = b'{"doNotOverwrite":true}\n'
        out.write_bytes(prior)
        rc = scan.main(
            [
                "--root",
                str(tree),
                "--policy",
                str(policy_path),
                "--output",
                str(out),
                "--expected-file-count",
                "1",
            ]
        )
        self.assertEqual(rc, 2)
        self.assertEqual(out.read_bytes(), prior)

    def test_production_policy_requires_manifest_binding_args(self) -> None:
        policy_path = ROOT / "manifests" / "security" / "release-fullbyte-scan-policy.s63i-hf2b.json"
        policy = scan.load_policy(policy_path)
        tree = self.tmp / "prod-bind"
        _write(tree / "x.bin", b"nope")
        report = scan.scan_tree(tree, policy)
        self.assertFalse(report["ok"])
        self.assertEqual(report["status"], "FAIL_MANIFEST_BINDING")


class RepoPolicyBindingTests(unittest.TestCase):
    def test_original_fail_receipt_reference_present(self) -> None:
        ref = ROOT / "manifests" / "security" / "ORIGINAL-FAIL-RECEIPT.REFERENCE.json"
        data = json.loads(ref.read_text(encoding="utf-8"))
        self.assertTrue(data["doNotRewrite"])
        self.assertEqual(
            data["windowsReceiptSha256"].upper(),
            "CBFED2C99D0BBB17E071108B07D1C9895B21D4461365B9795FCD10FED2801401",
        )
        policy_path = ROOT / "manifests" / "security" / "release-fullbyte-scan-policy.s63i-hf2b.json"
        policy_sha = hashlib.sha256(policy_path.read_bytes()).hexdigest().upper()
        self.assertEqual(data["policySha256AtCommit"], policy_sha)


if __name__ == "__main__":
    unittest.main()
