#!/usr/bin/env python3
"""Occurrence-aware full-byte release secret scanner (fail-closed).

Scans every file under a release root for provider-token families and
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
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


REPORT_SCHEMA = "xdisplay-ai.release-fullbyte-secret-scan.v2"
SCANNER_MODULE = "release_fullbyte_secret_scan.py"

RULE_PROVIDER = "provider-token-prefix"
RULE_PEM = "private-pem-header"

# Keep PEM header set as a reviewed superset; additional real-tree hits are NOT
# silently exempted by the 18 exact public-constant exceptions.
PEM_HEADERS: Tuple[bytes, ...] = (
    b"-----BEGIN RSA PRIVATE KEY-----",
    b"-----BEGIN EC PRIVATE KEY-----",
    b"-----BEGIN OPENSSH PRIVATE KEY-----",
    b"-----BEGIN DSA PRIVATE KEY-----",
    b"-----BEGIN PRIVATE KEY-----",
)

# Reviewed provider-family superset (prior frozen-release coverage + sk).
# sk threshold 24 matches prior scanner; left boundary avoids mid-token matches.
PROVIDER_FAMILY_PATTERNS: Tuple[Tuple[str, re.Pattern[bytes]], ...] = (
    ("sk", re.compile(rb"(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{24,}")),
    ("ghp", re.compile(rb"(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{36,}")),
    ("gho", re.compile(rb"(?<![A-Za-z0-9_])gho_[A-Za-z0-9]{36,}")),
    ("ghu", re.compile(rb"(?<![A-Za-z0-9_])ghu_[A-Za-z0-9]{36,}")),
    ("ghs", re.compile(rb"(?<![A-Za-z0-9_])ghs_[A-Za-z0-9]{36,}")),
    ("github_pat", re.compile(rb"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}")),
    ("akia", re.compile(rb"(?<![A-Za-z0-9_])AKIA[A-Z0-9]{16}")),
)

PROVIDER_FAMILY_IDS: Tuple[str, ...] = tuple(name for name, _ in PROVIDER_FAMILY_PATTERNS)

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
DISPOSITION_TRAVERSAL = "REJECTED_TRAVERSAL_OR_MANIFEST"
DISPOSITION_OUTPUT = "REJECTED_UNSAFE_OR_EXISTING_OUTPUT"

EXCEPTION_BINDING_FIELDS = (
    "relativePath",
    "fileBytes",
    "fileSHA256",
    "rule",
    "offsetBasis",
    "offset",
    "length",
    "matchedBytesSHA256",
    "classification",
)

PROTECTED_OUTPUT_BASENAMES = {
    "final-release-receipt.json",
    "original-fail-receipt.reference.json",
    "proposed-exact-exceptions.not-active.json",
    "release-fullbyte-scan-policy.s63i-hf2b.json",
    "release_fullbyte_secret_scan.py",
    "invoke-releasefullbytesecretscan.ps1",
}


@dataclass(frozen=True)
class Occurrence:
    relative_path: str
    rule: str
    offset: int
    length: int
    matched_bytes_sha256: str
    complete_pem: bool = False
    provider_family: str = ""


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


class ScanTraversalError(OSError):
    """Fail-closed traversal / symlink / enumeration error."""


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
    # Do NOT use str.lstrip("./") — that strips any leading '.' chars and would
    # turn ".git/hidden.bin" into "git/hidden.bin".
    p = path.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    while p.startswith("/"):
        p = p[1:]
    return p


def load_policy(path: Path) -> Dict[str, Any]:
    raw = path.read_bytes()
    policy = json.loads(raw.decode("utf-8"))
    policy["_policyFileSha256"] = hashlib.sha256(raw).hexdigest().upper()
    policy["_policyFileBytes"] = len(raw)
    policy["_policyPath"] = str(path.resolve())
    return policy


def _is_hex_sha256(value: str) -> bool:
    v = value.lower()
    return len(v) == 64 and all(c in "0123456789abcdef" for c in v)


def _proof_entry_problems(i: int, j: int, proof: Any, ex: Dict[str, Any]) -> List[str]:
    problems: List[str] = []
    if not isinstance(proof, dict):
        return [f"exception[{i}].publicSourceProof[{j}] is not an object"]
    for field in ("sourceFile", "rule", "line", "length", "matchedBytesSHA256"):
        if field not in proof:
            problems.append(f"exception[{i}].publicSourceProof[{j}] missing {field}")
    if problems:
        return problems
    if not str(proof.get("sourceFile") or "").strip():
        problems.append(f"exception[{i}].publicSourceProof[{j}] sourceFile empty")
    if str(proof.get("rule")) != str(ex.get("rule")):
        problems.append(
            f"exception[{i}].publicSourceProof[{j}] rule mismatch with exception"
        )
    try:
        line = int(proof["line"])
        length = int(proof["length"])
    except (TypeError, ValueError):
        problems.append(f"exception[{i}].publicSourceProof[{j}] line/length invalid")
        return problems
    if line <= 0:
        problems.append(f"exception[{i}].publicSourceProof[{j}] line must be > 0")
    if length != int(ex["length"]):
        problems.append(
            f"exception[{i}].publicSourceProof[{j}] length must equal exception length"
        )
    msha = str(proof.get("matchedBytesSHA256") or "").lower()
    if not _is_hex_sha256(msha):
        problems.append(
            f"exception[{i}].publicSourceProof[{j}] matchedBytesSHA256 malformed"
        )
    elif msha != str(ex.get("matchedBytesSHA256") or "").lower():
        problems.append(
            f"exception[{i}].publicSourceProof[{j}] matchedBytesSHA256 must equal exception digest"
        )
    return problems


def _exception_binding_key(raw: Dict[str, Any]) -> Tuple[Any, ...]:
    return (
        normalize_rel(str(raw.get("relativePath") or "")),
        int(raw.get("fileBytes") or -1),
        str(raw.get("fileSHA256") or "").lower(),
        str(raw.get("rule") or ""),
        str(raw.get("offsetBasis") or "ZERO_BASED_FILE_BYTE_OFFSET"),
        int(raw.get("offset") if "offset" in raw else -1),
        int(raw.get("length") or -1),
        str(raw.get("matchedBytesSHA256") or "").lower(),
        str(raw.get("classification") or ""),
    )


def _load_authoritative_proposed(policy: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], List[str]]:
    problems: List[str] = []
    binding = policy.get("evidenceBinding") or {}
    if not binding.get("requireExactProposedMatch"):
        return None, problems
    rel = binding.get("authoritativeProposedExceptionsRelativePath")
    if not rel:
        problems.append("evidenceBinding.authoritativeProposedExceptionsRelativePath missing")
        return None, problems
    policy_path = Path(str(policy.get("_policyPath") or ""))
    if not policy_path.is_file():
        problems.append("cannot resolve authoritative proposed exceptions without policy path")
        return None, problems
    proposed_path = (policy_path.parent / Path(str(rel))).resolve()
    if not proposed_path.is_file():
        problems.append(f"authoritative proposed exceptions missing: {proposed_path}")
        return None, problems
    try:
        proposed = json.loads(proposed_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        problems.append(f"failed to load authoritative proposed exceptions: {exc}")
        return None, problems
    return proposed, problems


def validate_policy_evidence(policy: Dict[str, Any]) -> List[str]:
    problems: List[str] = []
    exceptions = policy.get("exceptions")
    if not isinstance(exceptions, list):
        problems.append("policy.exceptions missing or not a list")
        return problems

    expected = int(policy.get("occurrenceCount") or 0)
    if expected != len(exceptions):
        problems.append(
            f"occurrenceCount {expected} != exceptions length {len(exceptions)}"
        )
    binding = policy.get("evidenceBinding") or {}
    if len(exceptions) == 0 and binding.get("requireExactProposedMatch"):
        problems.append("production evidence-bound policy cannot have zero exceptions")
        return problems

    families = policy.get("providerFamilies")
    if families is not None:
        if list(families) != list(PROVIDER_FAMILY_IDS):
            problems.append(
                "policy.providerFamilies must exactly equal scanner PROVIDER_FAMILY_IDS"
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
            "offsetBasis",
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
        if str(raw.get("offsetBasis")) != "ZERO_BASED_FILE_BYTE_OFFSET":
            problems.append(f"exception[{i}] offsetBasis must be ZERO_BASED_FILE_BYTE_OFFSET")

        proof = raw.get("publicSourceProof")
        if not isinstance(proof, list) or not proof:
            problems.append(f"exception[{i}] missing publicSourceProof")
        else:
            for j, entry in enumerate(proof):
                problems.extend(_proof_entry_problems(i, j, entry, raw))

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
        if not _is_hex_sha256(fsha):
            problems.append(f"exception[{i}] fileSHA256 malformed")
        if not _is_hex_sha256(msha):
            problems.append(f"exception[{i}] matchedBytesSHA256 malformed")

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
    else:
        problems.append("policy.explicitlyNotAllowed missing")

    limitations = policy.get("limitations") or {}
    if limitations.get("ffmpegUnsignedDistributorProvenance") not in (
        "NOT_PROVEN",
        "UNVERIFIED",
    ):
        problems.append(
            "policy must document FFmpeg unsigned distributor provenance as not proven"
        )

    proposed, proposed_problems = _load_authoritative_proposed(policy)
    problems.extend(proposed_problems)
    if proposed is not None:
        proposed_exceptions = proposed.get("exceptions")
        if not isinstance(proposed_exceptions, list):
            problems.append("authoritative proposed exceptions.exceptions missing")
        elif len(proposed_exceptions) != len(exceptions):
            problems.append(
                "active exceptions count must equal authoritative proposed exceptions count"
            )
        else:
            proposed_by_key = {}
            for pex in proposed_exceptions:
                if not isinstance(pex, dict):
                    continue
                proposed_by_key[_exception_binding_key(pex)] = pex
            for i, raw in enumerate(exceptions):
                if not isinstance(raw, dict):
                    continue
                key = _exception_binding_key(raw)
                if key not in proposed_by_key:
                    problems.append(
                        f"exception[{i}] binding does not match authoritative proposed evidence"
                    )
                else:
                    # Proof digests/schema must also match the reviewed proposal entries.
                    prop = proposed_by_key[key]
                    prop_proof = prop.get("publicSourceProof") or []
                    act_proof = raw.get("publicSourceProof") or []
                    if len(prop_proof) != len(act_proof):
                        problems.append(
                            f"exception[{i}] publicSourceProof length differs from proposed evidence"
                        )
                    else:
                        for j, (a, b) in enumerate(zip(act_proof, prop_proof)):
                            for field in (
                                "sourceFile",
                                "rule",
                                "line",
                                "length",
                                "matchedBytesSHA256",
                            ):
                                av = a.get(field) if isinstance(a, dict) else None
                                bv = b.get(field) if isinstance(b, dict) else None
                                if isinstance(av, str) and isinstance(bv, str) and field.endswith("SHA256"):
                                    av, bv = av.lower(), bv.lower()
                                if av != bv:
                                    problems.append(
                                        f"exception[{i}].publicSourceProof[{j}].{field} "
                                        "differs from proposed evidence"
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
    body = between.lstrip(b"\r\n")
    if not body:
        return False
    if set(body) <= {0}:
        return False
    sample = body.replace(b"\n", b"").replace(b"\r", b"").replace(b" ", b"")
    if len(sample) < 16:
        return False
    allowed = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    if sum(1 for c in sample[:64] if c in allowed) < max(16, len(sample[:64]) * 3 // 4):
        return False
    return True


def find_occurrences(relative_path: str, data: bytes) -> List[Occurrence]:
    found: List[Occurrence] = []
    seen: set[Tuple[int, int, str]] = set()

    for family, pattern in PROVIDER_FAMILY_PATTERNS:
        for m in pattern.finditer(data):
            matched = m.group(0)
            digest = sha256_hex(matched)
            key = (m.start(), len(matched), digest)
            if key in seen:
                continue
            seen.add(key)
            found.append(
                Occurrence(
                    relative_path=relative_path,
                    rule=RULE_PROVIDER,
                    offset=m.start(),
                    length=len(matched),
                    matched_bytes_sha256=digest,
                    complete_pem=False,
                    provider_family=family,
                )
            )

    for header in PEM_HEADERS:
        start = 0
        while True:
            idx = data.find(header, start)
            if idx < 0:
                break
            complete = _has_complete_pem_after(data, idx, len(header))
            digest = sha256_hex(header)
            key = (idx, len(header), digest)
            if key not in seen:
                seen.add(key)
                found.append(
                    Occurrence(
                        relative_path=relative_path,
                        rule=RULE_PEM,
                        offset=idx,
                        length=len(header),
                        matched_bytes_sha256=digest,
                        complete_pem=complete,
                    )
                )
            start = idx + 1

    found.sort(key=lambda o: (o.relative_path, o.rule, o.offset, o.length))
    return found


def _reject_unsupported_entry(path: Path) -> None:
    try:
        st = path.lstat()
    except OSError as exc:
        raise ScanTraversalError(f"failed to lstat release entry {path}: {exc}") from exc
    if stat.S_ISLNK(st.st_mode) or path.is_symlink():
        raise ScanTraversalError(f"unsupported symlink/reparse point in release tree: {path}")
    if path.is_dir():
        return
    if not stat.S_ISREG(st.st_mode):
        raise ScanTraversalError(f"unsupported non-regular file in release tree: {path}")


def iter_release_files(root: Path) -> Iterable[Path]:
    """Enumerate every file under root; never skip .git; fail closed on errors/symlinks."""

    def onerror(err: OSError) -> None:
        raise ScanTraversalError(f"directory enumeration failed: {err}") from err

    root = root.resolve()
    if root.is_symlink():
        raise ScanTraversalError(f"unsupported symlink/reparse release root: {root}")

    for dirpath, dirnames, filenames in os.walk(
        root, topdown=True, onerror=onerror, followlinks=False
    ):
        current = Path(dirpath)
        _reject_unsupported_entry(current)
        # Explicitly reject directory symlinks/reparse before descent.
        for name in list(dirnames):
            child = current / name
            _reject_unsupported_entry(child)
        for name in filenames:
            path = current / name
            _reject_unsupported_entry(path)
            yield path


def load_tree_manifest(path: Path) -> Dict[str, Any]:
    raw = path.read_bytes()
    payload = json.loads(raw.decode("utf-8"))
    payload["_manifestFileSha256"] = hashlib.sha256(raw).hexdigest().upper()
    payload["_manifestFileBytes"] = len(raw)
    return payload


def _manifest_entries(manifest: Dict[str, Any]) -> Dict[str, Tuple[int, str]]:
    files = manifest.get("files")
    if not isinstance(files, list):
        raise ScanTraversalError("tree manifest missing files[]")
    out: Dict[str, Tuple[int, str]] = {}
    for entry in files:
        if not isinstance(entry, dict):
            raise ScanTraversalError("tree manifest entry is not an object")
        rel = normalize_rel(str(entry.get("relativePath") or ""))
        if not rel:
            raise ScanTraversalError("tree manifest entry missing relativePath")
        try:
            size = int(entry["sizeBytes"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ScanTraversalError(f"tree manifest entry sizeBytes invalid for {rel}") from exc
        digest = str(entry.get("sha256") or "").lower()
        if not _is_hex_sha256(digest):
            raise ScanTraversalError(f"tree manifest entry sha256 invalid for {rel}")
        if rel in out:
            raise ScanTraversalError(f"duplicate tree manifest path: {rel}")
        out[rel] = (size, digest)
    return out


def is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def assert_safe_new_output(
    output: Path,
    *,
    release_root: Path,
    policy_path: Path,
    extra_protected: Optional[Sequence[Path]] = None,
) -> None:
    out = output if output.is_absolute() else (Path.cwd() / output)
    if out.exists():
        raise FileExistsError(
            f"output already exists (create-new/exclusive only): {out}"
        )
    if is_under(out, release_root):
        raise ValueError(f"refusing output inside release root: {out}")
    protected = [policy_path]
    if extra_protected:
        protected.extend(extra_protected)
    policy_dir = policy_path.resolve().parent
    protected.extend(
        [
            policy_dir / "ORIGINAL-FAIL-RECEIPT.REFERENCE.json",
            policy_dir / "PROPOSED-EXACT-EXCEPTIONS.NOT-ACTIVE.json",
            policy_dir / "release-fullbyte-scan-policy.s63i-hf2b.json",
            Path(__file__).resolve(),
            Path(__file__).resolve().parent / "Invoke-ReleaseFullByteSecretScan.ps1",
        ]
    )
    out_resolved = out.resolve(strict=False)
    for item in protected:
        try:
            item_resolved = item.resolve()
        except OSError:
            continue
        if out_resolved == item_resolved:
            raise ValueError(f"refusing to write over protected path: {out}")
    if out_resolved.name.lower() in PROTECTED_OUTPUT_BASENAMES:
        raise ValueError(f"refusing protected evidence/scanner/policy output name: {out}")


def write_report_exclusive(report: Dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    data = text.encode("utf-8")
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    fd = os.open(str(output), flags, 0o644)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
    except Exception:
        # Best-effort: if write fails mid-way, do not leave a partial "success" artifact
        # that later overwrites; exclusive create already prevented clobbering priors.
        raise


def scan_tree(
    root: Path,
    policy: Dict[str, Any],
    *,
    require_policy_ok: bool = True,
    expected_file_count: Optional[int] = None,
    tree_manifest: Optional[Dict[str, Any]] = None,
    scanner_path: Optional[Path] = None,
) -> Dict[str, Any]:
    evidence_problems = validate_policy_evidence(policy)
    exceptions = parse_exceptions(policy)
    scanner_file = scanner_path or Path(__file__)
    try:
        scanner_sha = sha256_file(scanner_file).upper()
        scanner_bytes = scanner_file.stat().st_size
    except OSError:
        scanner_sha = ""
        scanner_bytes = 0

    expected_tree = policy.get("expectedReleaseTree") or {}
    require_binding = bool(expected_tree.get("requireBinding"))

    report: Dict[str, Any] = {
        "schema": REPORT_SCHEMA,
        "generatedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scanRoot": str(root),
        "policyId": policy.get("policyId"),
        "policySha256": policy.get("_policyFileSha256"),
        "policyBytes": policy.get("_policyFileBytes"),
        "scannerModule": SCANNER_MODULE,
        "scannerSha256": scanner_sha,
        "scannerBytes": scanner_bytes,
        "providerFamilies": list(PROVIDER_FAMILY_IDS),
        "authorCard": policy.get("authorCard"),
        "gitleaksIndependent": True,
        "gitleaksNote": (policy.get("gitleaks") or {}).get("note"),
        "limitations": policy.get("limitations"),
        "preservedOriginalFailReceipt": policy.get("preservedOriginalFailReceipt"),
        "expectedFileCount": expected_file_count,
        "treeManifestSha256": (tree_manifest or {}).get("_manifestFileSha256"),
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
            {"disposition": DISPOSITION_EVIDENCE, "problem": p}
            for p in evidence_problems
        ]
        return report

    if require_binding:
        if expected_file_count is None:
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {
                    "disposition": DISPOSITION_TRAVERSAL,
                    "problem": "expectedReleaseTree.requireBinding needs --expected-file-count",
                }
            ]
            return report
        pinned_count = expected_tree.get("fileCount")
        if pinned_count is not None and int(pinned_count) != int(expected_file_count):
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {
                    "disposition": DISPOSITION_TRAVERSAL,
                    "problem": (
                        f"--expected-file-count {expected_file_count} != policy "
                        f"expectedReleaseTree.fileCount {pinned_count}"
                    ),
                }
            ]
            return report
        if tree_manifest is None:
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {
                    "disposition": DISPOSITION_TRAVERSAL,
                    "problem": "expectedReleaseTree.requireBinding needs --tree-manifest",
                }
            ]
            return report
        pinned_manifest_sha = str(expected_tree.get("manifestSha256") or "").upper()
        actual_manifest_sha = str(tree_manifest.get("_manifestFileSha256") or "").upper()
        if pinned_manifest_sha and pinned_manifest_sha != actual_manifest_sha:
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {
                    "disposition": DISPOSITION_TRAVERSAL,
                    "problem": (
                        "tree manifest SHA256 does not match policy "
                        "expectedReleaseTree.manifestSha256"
                    ),
                }
            ]
            return report

    file_cache: Dict[str, Tuple[int, str]] = {}
    all_occurrences: List[Occurrence] = []

    try:
        paths = sorted(
            iter_release_files(root),
            key=lambda p: normalize_rel(str(p.relative_to(root))),
        )
        for path in paths:
            rel = normalize_rel(str(path.relative_to(root)))
            data = path.read_bytes()
            size = len(data)
            digest = sha256_hex(data)
            file_cache[rel] = (size, digest)
            report["filesScanned"] += 1
            report["bytesScanned"] += size
            all_occurrences.extend(find_occurrences(rel, data))
    except (OSError, ScanTraversalError) as exc:
        report["status"] = "FAIL_SCAN_ERROR"
        report["remainingFindings"] = [
            {"disposition": DISPOSITION_ERROR, "problem": str(exc)}
        ]
        return report

    if expected_file_count is not None and int(expected_file_count) != int(report["filesScanned"]):
        report["status"] = "FAIL_MANIFEST_BINDING"
        report["remainingFindings"] = [
            {
                "disposition": DISPOSITION_TRAVERSAL,
                "problem": (
                    f"filesScanned {report['filesScanned']} != expected_file_count "
                    f"{expected_file_count}"
                ),
            }
        ]
        return report

    if tree_manifest is not None:
        try:
            expected_entries = _manifest_entries(tree_manifest)
        except ScanTraversalError as exc:
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {"disposition": DISPOSITION_TRAVERSAL, "problem": str(exc)}
            ]
            return report
        if set(expected_entries) != set(file_cache):
            missing = sorted(set(expected_entries) - set(file_cache))
            extra = sorted(set(file_cache) - set(expected_entries))
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {
                    "disposition": DISPOSITION_TRAVERSAL,
                    "problem": (
                        "scanned paths diverge from tree manifest; "
                        f"missing={len(missing)} extra={len(extra)}"
                    ),
                    "missingSample": missing[:20],
                    "extraSample": extra[:20],
                }
            ]
            return report
        mismatches = []
        for rel, (size, digest) in file_cache.items():
            exp_size, exp_digest = expected_entries[rel]
            if size != exp_size or digest != exp_digest:
                mismatches.append(rel)
        if mismatches:
            report["status"] = "FAIL_MANIFEST_BINDING"
            report["remainingFindings"] = [
                {
                    "disposition": DISPOSITION_TRAVERSAL,
                    "problem": "file size/sha256 mismatches versus tree manifest",
                    "mismatchSample": mismatches[:20],
                }
            ]
            return report

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
        }
        if occ.provider_family:
            row["providerFamily"] = occ.provider_family

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
        size, digest = meta
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
                size, digest = meta
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


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audited occurrence-aware full-byte release secret scan"
    )
    parser.add_argument("--root", required=True, help="Release tree root to scan")
    parser.add_argument("--policy", required=True, help="Active policy JSON path")
    parser.add_argument(
        "--output",
        required=True,
        help="NEW audited scan report path (create-new/exclusive; never overwrite)",
    )
    parser.add_argument(
        "--expected-file-count",
        type=int,
        default=None,
        help="Complete expected release file count (required when policy requireBinding)",
    )
    parser.add_argument(
        "--tree-manifest",
        default="",
        help="Complete tree manifest JSON (relativePath/sizeBytes/sha256 per file)",
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

    try:
        assert_safe_new_output(output, release_root=root, policy_path=policy_path)
    except (FileExistsError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    policy = load_policy(policy_path)
    tree_manifest = None
    if args.tree_manifest:
        tree_manifest = load_tree_manifest(Path(args.tree_manifest))

    report = scan_tree(
        root,
        policy,
        expected_file_count=args.expected_file_count,
        tree_manifest=tree_manifest,
        scanner_path=Path(__file__),
    )
    if report["filesScanned"] == 0 and not args.allow_empty_tree:
        report["ok"] = False
        report["status"] = "FAIL_EMPTY_TREE"
        report["remainingFindings"] = [
            {
                "disposition": DISPOSITION_ERROR,
                "problem": "scan root contained no files",
            }
        ]

    try:
        write_report_exclusive(report, output)
    except FileExistsError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"FAIL: could not create exclusive report output: {exc}", file=sys.stderr)
        return 2

    print(
        json.dumps(
            {
                "ok": report["ok"],
                "status": report["status"],
                "schema": report["schema"],
                "policySha256": report["policySha256"],
                "scannerSha256": report["scannerSha256"],
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
