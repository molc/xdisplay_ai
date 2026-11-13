#!/usr/bin/env python3
"""Occurrence-aware full-byte release secret scanner (fail-closed).

Scans every file under a release root for provider-token-prefix and
private-pem-header byte patterns. Exact public-constant exceptions are
bounded by relative path + whole-file size/SHA256 + rule + offset + length
+ matched-byte SHA256. Does not print raw matched secret bytes.

Empty gitleaks [] is independent and never treated as gate PASS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


RULE_PROVIDER = "provider-token-prefix"
RULE_PEM = "private-pem-header"

PEM_HEADERS: Tuple[bytes, ...] = (
    b"-----BEGIN RSA PRIVATE KEY-----",
    b"-----BEGIN EC PRIVATE KEY-----",
    b"-----BEGIN OPENSSH PRIVATE KEY-----",
    b"-----BEGIN DSA PRIVATE KEY-----",
    b"-----BEGIN PRIVATE KEY-----",
)

# sk- + contiguous [A-Za-z0-9_-] (stops before '@' and other separators)
_PROVIDER_RE = re.compile(rb"sk-[A-Za-z0-9_-]{20,}")

_END_FOOTER_RE = re.compile(
    rb"-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
)

DISPOSITION_EXEMPTED = "EXEMPTED_PUBLIC_CONSTANT"
DISPOSITION_FINDING = "FINDING"
DISPOSITION_COMPLETE_PEM = "REJECTED_COMPLETE_PEM"
DISPOSITION_HASH_MISMATCH = "REJECTED_FILE_HASH_OR_SIZE_MISMATCH"
DISPOSITION_UNUSED = "REJECTED_UNUSED_EXCEPTION"
DISPOSITION_AMBIGUOUS = "REJECTED_AMBIGUOUS_OR_DUPLICATE_EXCEPTION"
DISPOSITION_EVIDENCE = "REJECTED_POLICY_EVIDENCE"
DISPOSITION_ERROR = "SCAN_ERROR"


@dataclass(frozen=True)
class Occurrence:
    relative_path: str
    rule: str
    offset: int
    length: int
    matched_bytes_sha256: str
    complete_pem: bool = False


@dataclass(frozen=True)
class ExceptionSpec:
    index: int
    relative_path: str
    file_bytes: int
    file_sha256: str
    rule: str
    offset: int
    length: int
    matched_bytes_sha256: str
    classification: str
    active: bool
    public_source_proof: Sequence[Any]


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().lower()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest().lower()


def normalize_rel(path: str) -> str:
    return path.replace("\\", "/").lstrip("./")


def load_policy(path: Path) -> Dict[str, Any]:
    raw = path.read_bytes()
    policy = json.loads(raw.decode("utf-8"))
    policy["_policyFileSha256"] = hashlib.sha256(raw).hexdigest().upper()
    policy["_policyFileBytes"] = len(raw)
    return policy


def validate_policy_evidence(policy: Dict[str, Any]) -> List[str]:
    problems: List[str] = []
    exceptions = policy.get("exceptions")
    if not isinstance(exceptions, list) or not exceptions:
        problems.append("policy.exceptions missing or empty")
        return problems

    expected = int(policy.get("occurrenceCount") or 0)
    if expected and expected != len(exceptions):
        problems.append(
            f"occurrenceCount {expected} != exceptions length {len(exceptions)}"
        )

    seen: Dict[Tuple[str, str, int], int] = {}
    for i, raw in enumerate(exceptions):
        if not isinstance(raw, dict):
            problems.append(f"exception[{i}] is not an object")
            continue
        if not raw.get("active", False):
            problems.append(f"exception[{i}] is not active")
        for field in (
            "relativePath",
            "fileSHA256",
            "rule",
            "matchedBytesSHA256",
            "classification",
        ):
            if not raw.get(field):
                problems.append(f"exception[{i}] missing {field}")
        try:
            file_bytes = int(raw["fileBytes"])
            length = int(raw["length"])
            offset = int(raw["offset"])
        except (KeyError, TypeError, ValueError):
            problems.append(f"exception[{i}] fileBytes/offset/length missing or invalid")
            continue
        if file_bytes <= 0:
            problems.append(f"exception[{i}] fileBytes invalid")
        if length <= 0:
            problems.append(f"exception[{i}] length invalid")
        if offset < 0:
            problems.append(f"exception[{i}] offset invalid")
        proof = raw.get("publicSourceProof")
        if not isinstance(proof, list) or not proof:
            problems.append(f"exception[{i}] missing publicSourceProof")
        key = (
            normalize_rel(str(raw.get("relativePath") or "")),
            str(raw.get("rule") or ""),
            offset,
        )
        if key in seen:
            problems.append(
                f"duplicated/ambiguous exception key path+rule+offset: {key} "
                f"(indexes {seen[key]} and {i})"
            )
        else:
            seen[key] = i

        fsha = str(raw.get("fileSHA256") or "").lower()
        msha = str(raw.get("matchedBytesSHA256") or "").lower()
        if len(fsha) != 64 or any(c not in "0123456789abcdef" for c in fsha):
            problems.append(f"exception[{i}] fileSHA256 malformed")
        if len(msha) != 64 or any(c not in "0123456789abcdef" for c in msha):
            problems.append(f"exception[{i}] matchedBytesSHA256 malformed")

        # Never allow snakeoil / real private-key allowances as public constants.
        classification = str(raw.get("classification") or "").upper()
        if "SNAKEOIL" in classification:
            problems.append(f"exception[{i}] must not activate backend snakeoil allowance")
        if classification in {
            "COMPLETE_PEM",
            "COMPLETE_PRIVATE_KEY",
            "REAL_PROVIDER_TOKEN",
        }:
            problems.append(f"exception[{i}] classification is not a public-constant exception")

    if policy.get("explicitlyNotAllowed"):
        banned = {str(x) for x in policy["explicitlyNotAllowed"]}
        if "backend_companion_snakeoil_complete_pem" not in banned:
            problems.append("policy must explicitly refuse backend snakeoil allowance")

    limitations = policy.get("limitations") or {}
    if limitations.get("ffmpegUnsignedDistributorProvenance") not in (
        "NOT_PROVEN",
        "UNVERIFIED",
    ):
        problems.append(
            "policy must document FFmpeg unsigned distributor provenance as not proven"
        )

    return problems


def parse_exceptions(policy: Dict[str, Any]) -> List[ExceptionSpec]:
    out: List[ExceptionSpec] = []
    for i, raw in enumerate(policy.get("exceptions") or []):
        out.append(
            ExceptionSpec(
                index=i,
                relative_path=normalize_rel(str(raw["relativePath"])),
                file_bytes=int(raw["fileBytes"]),
                file_sha256=str(raw["fileSHA256"]).lower(),
                rule=str(raw["rule"]),
                offset=int(raw["offset"]),
                length=int(raw["length"]),
                matched_bytes_sha256=str(raw["matchedBytesSHA256"]).lower(),
                classification=str(raw.get("classification") or ""),
                active=bool(raw.get("active", False)),
                public_source_proof=list(raw.get("publicSourceProof") or []),
            )
        )
    return out


def _has_complete_pem_after(data: bytes, header_offset: int, header_len: int) -> bool:
    """True if a PEM header is followed by body bytes and a matching END footer."""
    rest = data[header_offset + header_len : header_offset + header_len + 16384]
    m = _END_FOOTER_RE.search(rest)
    if not m:
        return False
    between = rest[: m.start()]
    # Strip a single leading newline common in PEM text.
    body = between.lstrip(b"\r\n")
    if not body:
        # Header immediately followed by footer — still treat as incomplete / header-only.
        return False
    # Reject if body is only NULs (standalone NUL-terminated header constant).
    if set(body) <= {0}:
        return False
    # Require some base64-ish content.
    sample = body.replace(b"\n", b"").replace(b"\r", b"").replace(b" ", b"")
    if len(sample) < 16:
        return False
    allowed = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    if sum(1 for c in sample[:64] if c in allowed) < max(16, len(sample[:64]) * 3 // 4):
        return False
    return True


def find_occurrences(relative_path: str, data: bytes) -> List[Occurrence]:
    found: List[Occurrence] = []

    for m in _PROVIDER_RE.finditer(data):
        matched = m.group(0)
        found.append(
            Occurrence(
                relative_path=relative_path,
                rule=RULE_PROVIDER,
                offset=m.start(),
                length=len(matched),
                matched_bytes_sha256=sha256_hex(matched),
                complete_pem=False,
            )
        )

    for header in PEM_HEADERS:
        start = 0
        while True:
            idx = data.find(header, start)
            if idx < 0:
                break
            complete = _has_complete_pem_after(data, idx, len(header))
            found.append(
                Occurrence(
                    relative_path=relative_path,
                    rule=RULE_PEM,
                    offset=idx,
                    length=len(header),
                    matched_bytes_sha256=sha256_hex(header),
                    complete_pem=complete,
                )
            )
            start = idx + 1

    found.sort(key=lambda o: (o.relative_path, o.rule, o.offset, o.length))
    return found


def iter_release_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        # Keep full-file coverage; only skip VCS metadata directories.
        dirnames[:] = [d for d in dirnames if d not in {".git"}]
        for name in filenames:
            yield Path(dirpath) / name


def scan_tree(
    root: Path,
    policy: Dict[str, Any],
    *,
    require_policy_ok: bool = True,
) -> Dict[str, Any]:
    evidence_problems = validate_policy_evidence(policy)
    exceptions = parse_exceptions(policy)

    report: Dict[str, Any] = {
        "schema": "xdisplay-ai.release-fullbyte-secret-scan.v1",
        "generatedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scanRoot": str(root),
        "policyId": policy.get("policyId"),
        "policySha256": policy.get("_policyFileSha256"),
        "policyBytes": policy.get("_policyFileBytes"),
        "authorCard": policy.get("authorCard"),
        "gitleaksIndependent": True,
        "gitleaksNote": (policy.get("gitleaks") or {}).get("note"),
        "limitations": policy.get("limitations"),
        "preservedOriginalFailReceipt": policy.get("preservedOriginalFailReceipt"),
        "filesScanned": 0,
        "bytesScanned": 0,
        "occurrences": [],
        "remainingFindings": [],
        "policyEvidenceProblems": evidence_problems,
        "unusedExceptions": [],
        "status": "FAIL",
        "ok": False,
        "rawMatchedSecretsEmitted": False,
    }

    if evidence_problems and require_policy_ok:
        report["status"] = "FAIL_POLICY_EVIDENCE"
        report["remainingFindings"] = [
            {
                "disposition": DISPOSITION_EVIDENCE,
                "problem": p,
            }
            for p in evidence_problems
        ]
        return report

    # Ambiguous duplicates among active exceptions already collected in evidence_problems;
    # also detect runtime ambiguous matches (multiple exceptions claim one occurrence).
    file_cache: Dict[str, Tuple[int, str, bytes]] = {}
    all_occurrences: List[Occurrence] = []

    try:
        for path in sorted(iter_release_files(root), key=lambda p: normalize_rel(str(p.relative_to(root)))):
            rel = normalize_rel(str(path.relative_to(root)))
            data = path.read_bytes()
            size = len(data)
            digest = sha256_hex(data)
            file_cache[rel] = (size, digest, data)
            report["filesScanned"] += 1
            report["bytesScanned"] += size
            all_occurrences.extend(find_occurrences(rel, data))
    except OSError as exc:
        report["status"] = "FAIL_SCAN_ERROR"
        report["remainingFindings"] = [
            {"disposition": DISPOSITION_ERROR, "problem": str(exc)}
        ]
        return report

    # Index exceptions by occurrence identity (path, rule, offset, length, matched digest)
    exception_by_occ: Dict[Tuple[str, str, int, int, str], List[ExceptionSpec]] = {}
    for ex in exceptions:
        if not ex.active:
            continue
        key = (
            ex.relative_path,
            ex.rule,
            ex.offset,
            ex.length,
            ex.matched_bytes_sha256,
        )
        exception_by_occ.setdefault(key, []).append(ex)

    used_exception_indexes: set[int] = set()
    occurrence_rows: List[Dict[str, Any]] = []
    remaining: List[Dict[str, Any]] = []

    for occ in all_occurrences:
        key = (
            occ.relative_path,
            occ.rule,
            occ.offset,
            occ.length,
            occ.matched_bytes_sha256,
        )
        candidates = exception_by_occ.get(key, [])

        row: Dict[str, Any] = {
            "relativePath": occ.relative_path,
            "rule": occ.rule,
            "offset": occ.offset,
            "length": occ.length,
            "matchedBytesSHA256": occ.matched_bytes_sha256,
            "completePem": occ.complete_pem,
            # Never include raw matched bytes.
        }

        if occ.complete_pem:
            row["disposition"] = DISPOSITION_COMPLETE_PEM
            occurrence_rows.append(row)
            remaining.append(row)
            continue

        if not candidates:
            row["disposition"] = DISPOSITION_FINDING
            occurrence_rows.append(row)
            remaining.append(row)
            continue

        if len(candidates) > 1:
            row["disposition"] = DISPOSITION_AMBIGUOUS
            row["exceptionIndexes"] = [c.index for c in candidates]
            occurrence_rows.append(row)
            remaining.append(row)
            continue

        ex = candidates[0]
        meta = file_cache.get(occ.relative_path)
        if meta is None:
            row["disposition"] = DISPOSITION_FINDING
            occurrence_rows.append(row)
            remaining.append(row)
            continue
        size, digest, _data = meta
        if size != ex.file_bytes or digest != ex.file_sha256:
            row["disposition"] = DISPOSITION_HASH_MISMATCH
            row["actualFileBytes"] = size
            row["actualFileSHA256"] = digest
            row["expectedFileBytes"] = ex.file_bytes
            row["expectedFileSHA256"] = ex.file_sha256
            occurrence_rows.append(row)
            remaining.append(row)
            continue

        row["disposition"] = DISPOSITION_EXEMPTED
        row["exceptionIndex"] = ex.index
        row["classification"] = ex.classification
        used_exception_indexes.add(ex.index)
        occurrence_rows.append(row)

    unused = []
    for ex in exceptions:
        if not ex.active:
            continue
        if ex.index not in used_exception_indexes:
            # If the file is present but hash differs, still unused/mismatch.
            meta = file_cache.get(ex.relative_path)
            entry = {
                "disposition": DISPOSITION_UNUSED,
                "exceptionIndex": ex.index,
                "relativePath": ex.relative_path,
                "rule": ex.rule,
                "offset": ex.offset,
                "length": ex.length,
                "matchedBytesSHA256": ex.matched_bytes_sha256,
            }
            if meta is not None:
                size, digest, _ = meta
                if size != ex.file_bytes or digest != ex.file_sha256:
                    entry["disposition"] = DISPOSITION_HASH_MISMATCH
                    entry["actualFileBytes"] = size
                    entry["actualFileSHA256"] = digest
                    entry["expectedFileBytes"] = ex.file_bytes
                    entry["expectedFileSHA256"] = ex.file_sha256
            unused.append(entry)
            remaining.append(entry)

    report["occurrences"] = occurrence_rows
    report["unusedExceptions"] = unused
    report["remainingFindings"] = remaining

    if remaining:
        report["status"] = "FAIL"
        report["ok"] = False
    else:
        report["status"] = "PASS"
        report["ok"] = True

    return report


def write_report(report: Dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    output.write_text(text, encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audited occurrence-aware full-byte release secret scan"
    )
    parser.add_argument("--root", required=True, help="Release tree root to scan")
    parser.add_argument("--policy", required=True, help="Active policy JSON path")
    parser.add_argument(
        "--output",
        required=True,
        help="Path for NEW audited scan report JSON (never rewrite original FAIL receipt)",
    )
    parser.add_argument(
        "--allow-empty-tree",
        action="store_true",
        help="Permit scanning an empty directory (tests only)",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    root = Path(args.root)
    policy_path = Path(args.policy)
    output = Path(args.output)

    if not root.is_dir():
        print(f"FAIL: scan root is not a directory: {root}", file=sys.stderr)
        return 2
    if not policy_path.is_file():
        print(f"FAIL: policy not found: {policy_path}", file=sys.stderr)
        return 2

    policy = load_policy(policy_path)
    report = scan_tree(root, policy)
    if report["filesScanned"] == 0 and not args.allow_empty_tree:
        report["ok"] = False
        report["status"] = "FAIL_EMPTY_TREE"
        report["remainingFindings"] = [
            {
                "disposition": DISPOSITION_ERROR,
                "problem": "scan root contained no files",
            }
        ]

    write_report(report, output)
    print(
        json.dumps(
            {
                "ok": report["ok"],
                "status": report["status"],
                "policySha256": report["policySha256"],
                "filesScanned": report["filesScanned"],
                "occurrenceCount": len(report["occurrences"]),
                "remainingFindingCount": len(report["remainingFindings"]),
                "output": str(output),
                "rawMatchedSecretsEmitted": False,
            },
            indent=2,
        )
    )
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
