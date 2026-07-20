#!/usr/bin/env python3
"""Validate an OpenConfig RFC 7951 instance against the pinned model set.

Governing specification: FS-162-HDS-010-SDS-020-SMS-010.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys
from typing import Any


FAIL_CLOSED_EXIT = 2
YANG_FAILURE_EXIT = 3


def emit(code: str, message: str, *, status: str, **details: Any) -> None:
    json.dump(
        {
            "code": code,
            "message": message,
            "status": status,
            **details,
        },
        sys.stderr if status == "NOT_OK" else sys.stdout,
        indent=2,
        sort_keys=True,
    )
    (sys.stderr if status == "NOT_OK" else sys.stdout).write("\n")


def fail(code: str, message: str, **details: Any) -> int:
    emit(code, message, status="NOT_OK", **details)
    return YANG_FAILURE_EXIT if code == "OC_YANG_VALIDATION_FAILED" else FAIL_CLOSED_EXIT


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate RFC 7951 JSON against pinned OpenConfig models"
    )
    parser.add_argument("instance", type=pathlib.Path)
    parser.add_argument("--model-root", required=True, type=pathlib.Path)
    parser.add_argument("--flake-lock", required=True, type=pathlib.Path)
    parser.add_argument("--expected-model-rev", required=True)
    parser.add_argument("--expected-instance-sha256")
    parser.add_argument("--bundle-identity")
    parser.add_argument("--renderer-identity")
    parser.add_argument("--model-catalog")
    return parser.parse_args()


def read_openconfig_lock(
    path: pathlib.Path, expected_revision: str
) -> tuple[dict[str, Any] | None, int | None]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        locked = payload["nodes"]["openconfig"]["locked"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        return None, fail(
            "OC_YANG_MODELS_UNLOCKED",
            "flake.lock does not contain a readable locked OpenConfig input",
            flakeLock=str(path),
            error=str(error),
        )

    if not isinstance(locked, dict):
        return None, fail(
            "OC_YANG_MODELS_UNLOCKED",
            "OpenConfig lock entry is not an object",
            flakeLock=str(path),
        )

    missing = [
        key
        for key in ("narHash", "rev")
        if not isinstance(locked.get(key), str) or not locked[key]
    ]
    if missing:
        return None, fail(
            "OC_YANG_MODELS_UNLOCKED",
            "OpenConfig lock entry lacks immutable pin fields",
            flakeLock=str(path),
            missing=missing,
        )

    if locked["rev"] != expected_revision:
        return None, fail(
            "OC_YANG_MODELS_UNLOCKED",
            "OpenConfig lock revision differs from the evaluated model input",
            actualRevision=locked["rev"],
            expectedRevision=expected_revision,
            flakeLock=str(path),
        )

    return locked, None


def main() -> int:
    args = parse_args()

    missing_identities = [
        name
        for name, value in (
            ("candidateInstanceSha256", args.expected_instance_sha256),
            ("bundleIdentity", args.bundle_identity),
            ("rendererIdentity", args.renderer_identity),
        )
        if not isinstance(value, str) or not value
    ]
    if missing_identities:
        return fail(
            "OC_YANG_IDENTITY_UNBOUND",
            "YANG validation request lacks required identity bindings",
            missingIdentities=missing_identities,
        )

    if isinstance(args.model_catalog, str) and args.model_catalog.startswith(
        ("http://", "https://")
    ):
        return fail(
            "OC_YANG_NETWORK_ACCESS_DETECTED",
            "mutable remote YANG catalog resolution is forbidden",
            modelCatalog=args.model_catalog,
            networkRequestSent=False,
        )

    if not args.instance.is_file():
        return fail(
            "OC_INSTANCE_DOCUMENT_INVALID",
            "instance document is not a regular file",
            instanceDocument=str(args.instance),
        )

    try:
        instance_payload = json.loads(args.instance.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return fail(
            "OC_INSTANCE_DOCUMENT_INVALID",
            "instance document is not readable JSON",
            error=str(error),
            instanceDocument=str(args.instance),
        )
    if not isinstance(instance_payload, dict):
        return fail(
            "OC_INSTANCE_DOCUMENT_INVALID",
            "instance document root must be an object",
            instanceDocument=str(args.instance),
        )

    instance_hash = hashlib.sha256(args.instance.read_bytes()).hexdigest()
    if instance_hash != args.expected_instance_sha256:
        return fail(
            "OC_INSTANCE_DOCUMENT_INVALID",
            "instance document digest differs from the bound candidate identity",
            actualInstanceSha256=instance_hash,
            expectedInstanceSha256=args.expected_instance_sha256,
            instanceDocument=str(args.instance),
        )

    locked, error_code = read_openconfig_lock(
        args.flake_lock, args.expected_model_rev
    )
    if error_code is not None:
        return error_code
    assert locked is not None

    interface_module = (
        args.model_root
        / "release"
        / "models"
        / "interfaces"
        / "openconfig-interfaces.yang"
    )
    iana_module = (
        args.model_root / "third_party" / "ietf" / "iana-if-type.yang"
    )
    missing_modules = [
        str(path)
        for path in (interface_module, iana_module)
        if not path.is_file()
    ]
    if missing_modules:
        return fail(
            "OC_YANG_MODULE_MISSING",
            "required pinned YANG module is absent",
            missingModules=missing_modules,
            modelRoot=str(args.model_root),
        )

    lock_hash = hashlib.sha256(args.flake_lock.read_bytes()).hexdigest()
    version_result = subprocess.run(
        ["yanglint", "--version"],
        capture_output=True,
        text=True,
        check=False,
    )
    if version_result.returncode != 0:
        return fail(
            "OC_YANG_VALIDATION_FAILED",
            "yanglint version probe failed",
            yanglintExitCode=version_result.returncode,
            yanglintStderr=version_result.stderr,
        )
    yanglint_version = (
        version_result.stdout.strip() or version_result.stderr.strip()
    )
    validated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    command = [
        "yanglint",
        "-t",
        "config",
        "-p",
        str(args.model_root / "release" / "models" / "interfaces"),
        "-p",
        str(args.model_root / "release" / "models" / "types"),
        "-p",
        str(args.model_root / "release" / "models"),
        "-p",
        str(args.model_root / "third_party" / "ietf"),
        str(interface_module),
        str(iana_module),
        str(args.instance),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return fail(
            "OC_YANG_VALIDATION_FAILED",
            "yanglint rejected the instance document",
            bundleIdentity=args.bundle_identity,
            candidateInstanceSha256=instance_hash,
            instanceDocument=str(args.instance),
            flakeLockSha256=lock_hash,
            modelRevision=locked["rev"],
            networkAccess=False,
            rendererIdentity=args.renderer_identity,
            yanglintVersion=yanglint_version,
            yanglintExitCode=result.returncode,
            yanglintStderr=result.stderr,
            yanglintStdout=result.stdout,
        )

    emit(
        "OC_YANG_VALIDATION_PASS",
        "instance document conforms to the pinned OpenConfig model set",
        status="OK",
        bundleIdentity=args.bundle_identity,
        candidateInstanceSha256=instance_hash,
        instanceDocument=str(args.instance),
        flakeLockSha256=lock_hash,
        modelRevision=locked["rev"],
        networkAccess=False,
        rendererIdentity=args.renderer_identity,
        validatedAt=validated_at,
        yanglintVersion=yanglint_version,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
