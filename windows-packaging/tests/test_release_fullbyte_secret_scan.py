#!/usr/bin/env python3
"""Unit tests for occurrence-aware full-byte release secret scanning."""

from __future__ import annotations

import hashlib
import json
import shutil
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
        "exceptions": exceptions,
        "explicitlyNotAllowed": [
            "filename_allowlist",
            "library_allowlist",
            "global_pattern_allowlist",
            "backend_companion_snakeoil_complete_pem",
            "empty_gitleaks_array_as_gate_pass",
        ],
        "limitations": {
            "ffmpegUnsignedDistributorProvenance": "NOT_PROVEN",
            "note": "unit test limitation note",
        },
        "gitleaks": {"independent": True, "note": "empty [] not enough"},
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


class FullByteScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fullbyte-scan-"))
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))

    def _scan(self, policy: dict, tree: Path) -> dict:
        raw = (json.dumps(policy, indent=2) + "\n").encode("utf-8")
        policy_path = self.tmp / "policy.json"
        policy_path.write_bytes(raw)
        loaded = scan.load_policy(policy_path)
        return scan.scan_tree(tree, loaded)

    def test_public_constant_digests_match_review(self) -> None:
        self.assertEqual(
            _sha(ALG),
            "3ba30ddc57c5e012f28276fa224e3485067a139cd220da03b730060afb01b2b9",
        )
        self.assertEqual(
            _sha(RSA),
            "8bcac7908eb950419537b91e19adc83ce2c9cbfdacf4f81157fdadfec11f7017",
        )
        self.assertEqual(
            _sha(EC),
            "33ea101ddbe7c33be8f143a2779736d0264a4f4c8f323331a4aa9a1f72d8ab2a",
        )
        self.assertEqual(
            _sha(OPENSSH),
            "03d104c669e3c7b6be7f989db8b12c8b910d3be8c1e2a73c9369d3cc0ba803b5",
        )
        self.assertEqual(
            _sha(PKCS8),
            "3021d90eb9437b2d8f30e8363695c4418b5e5f1870801b5c317e9398ee0f572d",
        )

    def test_exempted_nul_terminated_headers_and_algorithm_name(self) -> None:
        # Synthetic file mirroring reviewed public constants (not the real binaries).
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
            # NUL delimit PEM headers as in review.
            if matched.startswith(b"-----"):
                if offset > 0:
                    blob[offset - 1] = 0
                blob[offset + len(matched)] = 0
        # Suffix after algorithm name like real OpenSSH domain (not part of match).
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
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(len(report["occurrences"]), 5)
        self.assertTrue(all(o["disposition"] == scan.DISPOSITION_EXEMPTED for o in report["occurrences"]))
        self.assertFalse(report["rawMatchedSecretsEmitted"])
        dumped = json.dumps(report)
        self.assertNotIn("sk-ecdsa", dumped)
        self.assertNotIn("BEGIN RSA", dumped)

    def test_appended_secret_fails(self) -> None:
        data = bytearray(b"\x00" * 128)
        data[8 : 8 + len(ALG)] = ALG
        data[8 + len(ALG) : 8 + len(ALG) + 12] = b"@openssh.com"
        clean = bytes(data)
        rel = "fixture.dll"
        tree = self.tmp / "tree-append"
        # Append a second real-looking provider token.
        poisoned = clean + b"\n" + b"sk-" + (b"A" * 40)
        _write(tree / rel, poisoned)

        exceptions = [_ex(rel, clean, scan.RULE_PROVIDER, 8, ALG)]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        dispositions = {r["disposition"] for r in report["remainingFindings"]}
        self.assertIn(scan.DISPOSITION_FINDING, dispositions)
        # Original exception unused because file hash changed.
        self.assertTrue(
            any(
                r["disposition"]
                in {scan.DISPOSITION_UNUSED, scan.DISPOSITION_HASH_MISMATCH}
                for r in report["remainingFindings"]
            )
        )

    def test_changed_file_hash_fails(self) -> None:
        data = bytearray(b"\x00" * 64)
        data[4 : 4 + len(ALG)] = ALG
        original = bytes(data)
        altered = original + b"x"
        rel = "fixture.dll"
        tree = self.tmp / "tree-hash"
        _write(tree / rel, altered)
        exceptions = [_ex(rel, original, scan.RULE_PROVIDER, 4, ALG)]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        self.assertTrue(
            any(
                r["disposition"] == scan.DISPOSITION_HASH_MISMATCH
                for r in report["remainingFindings"]
            )
        )

    def test_extra_occurrence_fails(self) -> None:
        data = bytearray(b"\x00" * 128)
        data[4 : 4 + len(ALG)] = ALG
        data[80 : 80 + len(ALG)] = ALG
        blob = bytes(data)
        rel = "fixture.dll"
        tree = self.tmp / "tree-extra"
        _write(tree / rel, blob)
        # Only first occurrence excepted.
        exceptions = [_ex(rel, blob, scan.RULE_PROVIDER, 4, ALG)]
        report = self._scan(_mini_policy(exceptions), tree)
        self.assertFalse(report["ok"])
        findings = [
            r
            for r in report["remainingFindings"]
            if r.get("disposition") == scan.DISPOSITION_FINDING
        ]
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["offset"], 80)

    def test_offset_or_digest_mismatch_fails(self) -> None:
        data = bytearray(b"\x00" * 64)
        data[4 : 4 + len(ALG)] = ALG
        blob = bytes(data)
        rel = "fixture.dll"
        tree = self.tmp / "tree-mismatch"
        _write(tree / rel, blob)

        bad_offset = _ex(rel, blob, scan.RULE_PROVIDER, 5, ALG)  # wrong offset
        report = self._scan(_mini_policy([bad_offset]), tree)
        self.assertFalse(report["ok"])

        bad_digest = _ex(rel, blob, scan.RULE_PROVIDER, 4, ALG)
        bad_digest["matchedBytesSHA256"] = "0" * 64
        report2 = self._scan(_mini_policy([bad_digest]), tree)
        self.assertFalse(report2["ok"])

    def test_complete_pem_not_exempted(self) -> None:
        # Minimal complete PEM body (not a real key; synthetic base64).
        body = b"MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA"
        pem = RSA + b"\n" + body + b"\n-----END RSA PRIVATE KEY-----\n"
        rel = "snakeoil.pem"
        tree = self.tmp / "tree-pem"
        _write(tree / rel, pem)

        # Even with an exact exception on the header bytes, complete PEM must fail.
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
            any(
                r["disposition"] == scan.DISPOSITION_COMPLETE_PEM
                for r in report["remainingFindings"]
            )
        )

    def test_active_policy_file_evidence_and_count(self) -> None:
        policy_path = ROOT / "manifests" / "security" / "release-fullbyte-scan-policy.s63i-hf2b.json"
        self.assertTrue(policy_path.is_file())
        policy = scan.load_policy(policy_path)
        problems = scan.validate_policy_evidence(policy)
        self.assertEqual(problems, [], problems)
        self.assertEqual(len(policy["exceptions"]), 18)
        self.assertTrue(all(ex.get("active") is True for ex in policy["exceptions"]))
        self.assertEqual(
            policy["limitations"]["ffmpegUnsignedDistributorProvenance"], "NOT_PROVEN"
        )
        self.assertIn(
            "backend_companion_snakeoil_complete_pem",
            policy["explicitlyNotAllowed"],
        )
        # No snakeoil allowance entries.
        for ex in policy["exceptions"]:
            self.assertNotIn("SNAKEOIL", str(ex.get("classification", "")).upper())

    def test_duplicated_exception_fails_policy_evidence(self) -> None:
        data = b"\x00" * 32 + ALG + b"\x00"
        rel = "fixture.dll"
        ex = _ex(rel, data, scan.RULE_PROVIDER, 32, ALG)
        policy = _mini_policy([ex, dict(ex)])
        problems = scan.validate_policy_evidence(policy)
        self.assertTrue(any("duplicated" in p for p in problems))

    def test_cli_writes_new_report_without_raw_secrets(self) -> None:
        data = bytearray(b"\x00" * 64)
        data[4 : 4 + len(ALG)] = ALG
        blob = bytes(data)
        tree = self.tmp / "cli-tree"
        _write(tree / "a.dll", blob)
        policy = _mini_policy([_ex("a.dll", blob, scan.RULE_PROVIDER, 4, ALG)])
        policy_path = self.tmp / "cli-policy.json"
        policy_path.write_text(json.dumps(policy, indent=2) + "\n", encoding="utf-8")
        out = self.tmp / "audited-report.json"
        rc = scan.main(
            [
                "--root",
                str(tree),
                "--policy",
                str(policy_path),
                "--output",
                str(out),
            ]
        )
        self.assertEqual(rc, 0)
        text = out.read_text(encoding="utf-8")
        self.assertIn("policySha256", text)
        self.assertIn("EXEMPTED_PUBLIC_CONSTANT", text)
        self.assertNotIn("sk-ecdsa", text)


class RepoPolicyBindingTests(unittest.TestCase):
    def test_original_fail_receipt_reference_present(self) -> None:
        ref = ROOT / "manifests" / "security" / "ORIGINAL-FAIL-RECEIPT.REFERENCE.json"
        data = json.loads(ref.read_text(encoding="utf-8"))
        self.assertTrue(data["doNotRewrite"])
        self.assertEqual(
            data["windowsReceiptSha256"].upper(),
            "CBFED2C99D0BBB17E071108B07D1C9895B21D4461365B9795FCD10FED2801401",
        )
        self.assertEqual(
            data["frozenTreeManifestSha256"].upper(),
            "5A2C4A23E9D7689F09C76281764CE929D26D45CAA23A28D7F6C9FA3058264A1B",
        )


if __name__ == "__main__":
    unittest.main()
