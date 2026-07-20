#!/usr/bin/env python3
"""Verify the portable FS-230 posture from one validated canonical bundle.

Governing specification: FS-162-HDS-010-SDS-040-SMS-010.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from typing import Any


FAIL_CLOSED_EXIT = 2
TRACE_ID = "FS-230-HDS-010-SDS-010-SMS-040"
RELATION_ID = f"{TRACE_ID}__lab-wan-to-nebula-ipv6"


def emit(stream: Any, code: str, message: str, status: str, **details: Any) -> None:
    json.dump(
        {"code": code, "message": message, "status": status, **details},
        stream,
        indent=2,
        sort_keys=True,
    )
    stream.write("\n")


def fail(code: str, message: str, **details: Any) -> int:
    emit(sys.stderr, code, message, "NOT_OK", **details)
    return FAIL_CLOSED_EXIT


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"unreadable JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("JSON root is not an object")
    return value


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_model_from_bundle(payload: dict[str, Any]) -> dict[str, Any]:
    if payload.get("kind") != "network-realization-bundle":
        raise ValueError("OC_RAW_CPM_INPUT: expected network-realization-bundle")
    validation = payload.get("validation")
    bundle_identity = payload.get("bundleIdentity")
    if (
        not isinstance(validation, dict)
        or validation.get("valid") is not True
        or validation.get("artifactIdentity") != bundle_identity
        or artifact_digest(payload) != bundle_identity
    ):
        raise ValueError("canonical bundle validation or digest is invalid")
    network = payload.get("network")
    model = network.get("data") if isinstance(network, dict) else None
    if not isinstance(model, dict):
        raise ValueError("canonical bundle lacks network.data")
    return model


def artifact_digest(payload: dict[str, Any]) -> str:
    identity_payload = {
        key: value
        for key, value in payload.items()
        if key not in {"bundleIdentity", "validation"}
    }
    return hashlib.sha256(
        json.dumps(
            identity_payload,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ).hexdigest()


def site_from_bundle(payload: dict[str, Any]) -> dict[str, Any]:
    model = canonical_model_from_bundle(payload)
    data = model.get("data")
    enterprise = data.get("mini-smt") if isinstance(data, dict) else None
    site = enterprise.get(TRACE_ID) if isinstance(enterprise, dict) else None
    if not isinstance(site, dict):
        raise ValueError(f"missing canonical network.data.data.mini-smt.{TRACE_ID}")
    return site


def mismatch(field: str, expected: Any, actual: Any) -> dict[str, Any]:
    return {"field": field, "expected": expected, "actual": actual}


def inspect_posture(site: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    runtime_targets = site.get("runtimeTargets")
    if not isinstance(runtime_targets, dict):
        raise ValueError("site lacks runtimeTargets")

    ingress_targets: list[tuple[str, dict[str, Any], dict[str, Any]]] = []
    for target_name, target in sorted(runtime_targets.items()):
        if not isinstance(target, dict):
            continue
        nat_intent = target.get("natIntent")
        public_ingress = (
            nat_intent.get("publicIngress") if isinstance(nat_intent, dict) else None
        )
        if isinstance(public_ingress, list) and public_ingress:
            ingress_targets.append((target_name, target, nat_intent))

    if len(ingress_targets) != 1:
        raise ValueError(
            f"expected one runtime target with public ingress, found {len(ingress_targets)}"
        )

    target_name, target, nat_intent = ingress_targets[0]
    public_ingress = nat_intent["publicIngress"]
    if len(public_ingress) != 1 or not isinstance(public_ingress[0], dict):
        raise ValueError("expected one public-ingress record")
    ingress = public_ingress[0]

    tuples = ingress.get("tupleRecords")
    expected_tuples = [{"protocol": "udp", "publicPort": 4242, "targetPort": 4242}]
    target_binding = ingress.get("target")
    runtime_destination = ingress.get("runtimeDestination")
    source_translation = ingress.get("sourceTranslation")
    egress_intent = target.get("egressIntent")

    checks = [
        ("family", 6, ingress.get("family")),
        ("tupleRecords", expected_tuples, tuples),
        ("translationMode", "none", ingress.get("translationMode")),
        ("sourcePreservation", "preserve-source", ingress.get("sourcePreservation")),
        ("returnBehavior", "stateful-return", ingress.get("returnBehavior")),
        ("destinationTranslation", False, ingress.get("destinationTranslation")),
        ("publicAddressBinding", "runtime-interface-address", ingress.get("publicAddressBinding")),
        ("relationId", RELATION_ID, ingress.get("relationId")),
        ("translationOwnerRuntimeTarget", target_name, ingress.get("translationOwnerRuntimeTarget")),
        ("natIntent.enabled", False, nat_intent.get("enabled")),
        ("natIntent.families", {"ipv4": False, "ipv6": False}, nat_intent.get("families")),
        ("natIntent.uplinks", [], nat_intent.get("uplinks")),
        ("egressIntent.explicit", True, egress_intent.get("explicit") if isinstance(egress_intent, dict) else None),
        ("egressIntent.eligible", False, egress_intent.get("eligible") if isinstance(egress_intent, dict) else None),
        ("egressIntent.exit", False, egress_intent.get("exit") if isinstance(egress_intent, dict) else None),
        ("egressIntent.upstreamSelection", False, egress_intent.get("upstreamSelection") if isinstance(egress_intent, dict) else None),
        ("egressIntent.uplinks", [], egress_intent.get("uplinks") if isinstance(egress_intent, dict) else None),
        ("egressIntent.wanInterfaces", [], egress_intent.get("wanInterfaces") if isinstance(egress_intent, dict) else None),
        ("sourceTranslation", {"address": None, "mode": "none", "owner": None}, source_translation),
        ("target.accessNode", "access-dmz", target_binding.get("accessNode") if isinstance(target_binding, dict) else None),
        ("target.endpoint", "nebula-lab-endpoint", target_binding.get("endpoint") if isinstance(target_binding, dict) else None),
        ("target.service", "nebula-lab", target_binding.get("service") if isinstance(target_binding, dict) else None),
        ("target.port", 4242, target_binding.get("port") if isinstance(target_binding, dict) else None),
        ("runtimeDestination.sourceClass", "protected", runtime_destination.get("sourceClass") if isinstance(runtime_destination, dict) else None),
        ("runtimeDestination.source", "intent-routed-prefix", runtime_destination.get("source") if isinstance(runtime_destination, dict) else None),
        ("runtimeDestination.targetPrefixLength", 128, runtime_destination.get("targetPrefixLength") if isinstance(runtime_destination, dict) else None),
        ("runtimeDestination.delegatedPrefixLength", 48, runtime_destination.get("delegatedPrefixLength") if isinstance(runtime_destination, dict) else None),
        ("runtimeDestination.perTenantPrefixLength", 64, runtime_destination.get("perTenantPrefixLength") if isinstance(runtime_destination, dict) else None),
        ("runtimeDestination.slot", 35, runtime_destination.get("slot") if isinstance(runtime_destination, dict) else None),
        ("runtimeDestination.interfaceIdentifier", "0:0:0:0:0:0:0:4242", runtime_destination.get("interfaceIdentifier") if isinstance(runtime_destination, dict) else None),
    ]
    mismatches = [mismatch(field, expected, actual) for field, expected, actual in checks if actual != expected]

    posture = {
        "addressFamily": "ipv6",
        "endpointBinding": {
            "accessNode": "access-dmz",
            "endpoint": "nebula-lab-endpoint",
            "service": "nebula-lab",
        },
        "inheritedPublicEgress": False,
        "interfaceIdentifier": "0:0:0:0:0:0:0:4242",
        "port": 4242,
        "protocol": "udp",
        "relationId": RELATION_ID,
        "returnBehavior": "stateful-return",
        "sourcePreservation": "preserve-source",
        "translationMode": "none",
    }
    return posture, mismatches


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the portable FS-230 posture from a canonical bundle"
    )
    parser.add_argument("bundle", type=pathlib.Path)
    parser.add_argument("--realization", required=True, choices=("nixos", "clab", "openconfig"))
    parser.add_argument("--canonical-intent", required=True, type=pathlib.Path)
    parser.add_argument("--compiler-revision", required=True)
    parser.add_argument("--cpm-revision", required=True)
    parser.add_argument("--network-labs-revision", required=True)
    parser.add_argument("--expected-bundle-identity")
    parser.add_argument("--peer-renderer-input", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.peer_renderer_input is not None:
        return fail(
            "OC_PEER_RENDERER_CONSUMED",
            "peer renderer output cannot supply OpenConfig posture fields",
            realization=args.realization,
        )

    try:
        payload = read_json(args.bundle)
        canonical_model = canonical_model_from_bundle(payload)
        intent_hash = sha256(args.canonical_intent)
        posture, mismatches = inspect_posture(site_from_bundle(payload))
    except (OSError, ValueError) as error:
        return fail(
            "OC_FS230_POSTURE_MISMATCH",
            "FS-230 canonical posture cannot be resolved",
            error=str(error),
            realization=args.realization,
        )

    bundle_identity = payload["bundleIdentity"]
    if (
        args.expected_bundle_identity is not None
        and bundle_identity != args.expected_bundle_identity
    ):
        return fail(
            "OC_FS230_BUNDLE_IDENTITY_MISMATCH",
            "peer comparison consumed a different canonical bundle identity",
            actualBundleIdentity=bundle_identity,
            expectedBundleIdentity=args.expected_bundle_identity,
            realization=args.realization,
        )

    if mismatches:
        return fail(
            "OC_FS230_POSTURE_MISMATCH",
            "FS-230 canonical posture differs from the controlled requirement",
            mismatches=mismatches,
            realization=args.realization,
        )

    emit(
        sys.stdout,
        "OC_FS230_POSTURE_PASS",
        "FS-230 posture is portable in one validated canonical bundle",
        "OK",
        bundleIdentity=bundle_identity,
        canonicalPortable=True,
        openConfigModelComplete=False,
        networkAccess=False,
        posture=posture,
        realization=args.realization,
        sourceIdentity={
            "canonicalIntentSha256": intent_hash,
            "bundleIdentity": bundle_identity,
            "compilerRevision": args.compiler_revision,
            "cpmRevision": args.cpm_revision,
            "networkLabsRevision": args.network_labs_revision,
            "sourceCpmIdentity": payload.get("sources", {})
            .get("cpm", {})
            .get("identity"),
        },
        limitations=[
            {
                "code": "OC_PROD_LIMITATION",
                "canonicalPath": "/network/data/data/mini-smt/*/runtimeTargets/*/natIntent/publicIngress",
                "openconfigPath": None,
                "reason": "selected OpenConfig model set does not yet express the complete ingress policy posture",
            }
        ],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
