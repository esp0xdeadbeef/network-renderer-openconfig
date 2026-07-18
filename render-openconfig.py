#!/usr/bin/env python3
"""Attempt a direct CPM-to-OpenConfig interfaces projection.

Governing specification: FS-162-HDS-010-SDS-030-SMS-010.

The current CPM has explicit runtime interface names but no authorized IANA
interface-type identity. The parser therefore records concrete field mappings
and gaps, emits no instance document, and exits fail-closed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any


FAIL_CLOSED_EXIT = 2


def diagnostic(code: str, message: str, **details: Any) -> None:
    record = {
        "code": code,
        "message": message,
        "status": "NOT_OK",
        **details,
    }
    json.dump(record, sys.stderr, indent=2, sort_keys=True)
    sys.stderr.write("\n")


def load_cpm(path: pathlib.Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        diagnostic(
            "OC_CPM_INPUT_INVALID",
            "CPM input is not readable JSON",
            inputPath=str(path),
            error=str(error),
        )
        raise SystemExit(FAIL_CLOSED_EXIT) from error

    if not isinstance(payload, dict):
        diagnostic(
            "OC_CPM_INPUT_INVALID",
            "CPM input root must be an object",
            inputPath=str(path),
        )
        raise SystemExit(FAIL_CLOSED_EXIT)
    return payload


def select_runtime_target(
    payload: dict[str, Any], target_name: str
) -> tuple[str, dict[str, Any]]:
    model = payload.get("control_plane_model")
    data = model.get("data") if isinstance(model, dict) else None
    if not isinstance(data, dict):
        diagnostic(
            "OC_CPM_CONTRACT_MISSING",
            "CPM input lacks control_plane_model.data",
            runtimeTarget=target_name,
        )
        raise SystemExit(FAIL_CLOSED_EXIT)

    matches: list[tuple[str, dict[str, Any]]] = []
    for enterprise_name, enterprise in sorted(data.items()):
        if not isinstance(enterprise, dict):
            continue
        for site_name, site in sorted(enterprise.items()):
            if not isinstance(site, dict):
                continue
            targets = site.get("runtimeTargets")
            if not isinstance(targets, dict):
                continue
            target = targets.get(target_name)
            if isinstance(target, dict):
                matches.append(
                    (
                        f"control_plane_model.data.{enterprise_name}.{site_name}"
                        f".runtimeTargets.{target_name}",
                        target,
                    )
                )

    if not matches:
        diagnostic(
            "OC_CPM_TARGET_MISSING",
            "runtime target does not exist in CPM input",
            runtimeTarget=target_name,
        )
        raise SystemExit(FAIL_CLOSED_EXIT)
    if len(matches) != 1:
        diagnostic(
            "OC_CPM_TARGET_AMBIGUOUS",
            "runtime target occurs more than once in CPM input",
            runtimeTarget=target_name,
            matches=[path for path, _target in matches],
        )
        raise SystemExit(FAIL_CLOSED_EXIT)
    return matches[0]


def present_string(record: dict[str, Any], key: str) -> bool:
    return isinstance(record.get(key), str) and bool(record[key])


def inspect_interface(
    target_path: str, logical_name: str, record: dict[str, Any]
) -> dict[str, Any]:
    interface_path = (
        f"{target_path}.effectiveRuntimeRealization.interfaces.{logical_name}"
    )
    mapped: list[dict[str, str]] = []
    gaps: list[dict[str, Any]] = []
    unsupported: list[dict[str, Any]] = []

    if present_string(record, "runtimeIfName"):
        for openconfig_path in ("name", "config.name"):
            mapped.append(
                {
                    "cpmPath": f"{interface_path}.runtimeIfName",
                    "openconfigPath": openconfig_path,
                }
            )
    else:
        gaps.append(
            {
                "code": "OC_CPM_PARSE_GAP",
                "cpmPath": f"{interface_path}.runtimeIfName",
                "openconfigPath": "name",
                "reason": "missing-explicit-runtime-interface-name",
            }
        )

    gaps.append(
        {
            "code": "OC_CPM_PARSE_GAP_TYPE",
            "cpmPath": None,
            "observedClassifications": {
                "adapterClass": record.get("adapterClass"),
                "sourceKind": record.get("sourceKind"),
            },
            "openconfigPath": "config.type",
            "reason": "no-iana-identity-in-cpm",
        }
    )

    optional_fields = (
        ("description", "config.description", lambda value: isinstance(value, str)),
        ("enabled", "config.enabled", lambda value: isinstance(value, bool)),
        (
            "mtu",
            "config.mtu",
            lambda value: isinstance(value, int)
            and not isinstance(value, bool)
            and 0 < value <= 65535,
        ),
    )
    for cpm_key, openconfig_path, valid in optional_fields:
        if valid(record.get(cpm_key)):
            mapped.append(
                {
                    "cpmPath": f"{interface_path}.{cpm_key}",
                    "openconfigPath": openconfig_path,
                }
            )
        else:
            gaps.append(
                {
                    "code": "OC_CPM_PARSE_GAP",
                    "cpmPath": f"{interface_path}.{cpm_key}",
                    "openconfigPath": openconfig_path,
                    "reason": "missing-explicit-cpm-value",
                }
            )

    parser_source_fields = {
        "adapterClass",
        "description",
        "enabled",
        "mtu",
        "runtimeIfName",
        "sourceKind",
    }
    for cpm_key in sorted(set(record) - parser_source_fields):
        unsupported.append(
            {
                "code": "OC_CPM_PARSE_UNSUPPORTED_FIELD",
                "cpmPath": f"{interface_path}.{cpm_key}",
                "openconfigPath": None,
                "reason": "not-covered-by-selected-openconfig-interfaces-surface",
            }
        )

    return {
        "cpmPath": interface_path,
        "gaps": gaps,
        "logicalInterface": logical_name,
        "mapped": mapped,
        "unsupported": unsupported,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Attempt a fail-closed CPM to OpenConfig projection"
    )
    parser.add_argument("cpm", type=pathlib.Path, help="CPM JSON artifact")
    parser.add_argument(
        "--runtime-target",
        required=True,
        help="exact CPM runtimeTargets key to inspect",
    )
    parser.add_argument(
        "--peer-renderer-input",
        type=pathlib.Path,
        help="forbidden peer-renderer artifact; accepted only to reject explicitly",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.peer_renderer_input is not None:
        diagnostic(
            "OC_CPM_PARSE_PEER_CONSUMED",
            "peer renderer artifacts cannot supply OpenConfig field values",
            artifactPath=str(args.peer_renderer_input),
        )
        return FAIL_CLOSED_EXIT

    payload = load_cpm(args.cpm)
    target_path, target = select_runtime_target(payload, args.runtime_target)

    realization = target.get("effectiveRuntimeRealization")
    interfaces = (
        realization.get("interfaces") if isinstance(realization, dict) else None
    )
    if not isinstance(interfaces, dict) or not interfaces:
        diagnostic(
            "OC_CPM_INTERFACES_MISSING",
            "runtime target has no effectiveRuntimeRealization.interfaces records",
            runtimeTarget=args.runtime_target,
            targetPath=target_path,
        )
        return FAIL_CLOSED_EXIT

    inspected = [
        inspect_interface(target_path, logical_name, record)
        for logical_name, record in sorted(interfaces.items())
        if isinstance(record, dict)
    ]
    if len(inspected) != len(interfaces):
        diagnostic(
            "OC_CPM_INTERFACE_INVALID",
            "one or more interface records are not objects",
            runtimeTarget=args.runtime_target,
            targetPath=target_path,
        )
        return FAIL_CLOSED_EXIT

    diagnostic(
        "OC_CPM_PARSE_GAP_TYPE",
        "current CPM cannot authorize a schema-mandatory OpenConfig interface type",
        interfaces=inspected,
        runtimeTarget=args.runtime_target,
        summary={
            "gapped": sum(len(item["gaps"]) for item in inspected),
            "interfaces": len(inspected),
            "mapped": sum(len(item["mapped"]) for item in inspected),
            "unsupported": sum(len(item["unsupported"]) for item in inspected),
        },
        targetPath=target_path,
    )
    return FAIL_CLOSED_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
