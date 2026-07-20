#!/usr/bin/env python3
"""Render validated canonical interface objects to OpenConfig JSON_IETF."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
from typing import Any


FAIL_CLOSED_EXIT = 2
YANG_FAILURE_EXIT = 3


def diagnostic(code: str, message: str, **details: Any) -> int:
    json.dump(
        {"code": code, "message": message, "status": "NOT_OK", **details},
        sys.stderr,
        indent=2,
        sort_keys=True,
    )
    sys.stderr.write("\n")
    return YANG_FAILURE_EXIT if code == "OC_YANG_VALIDATION_FAILED" else FAIL_CLOSED_EXIT


def load_json(path: pathlib.Path, code: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{code}: {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{code}: {path}: root must be an object")
    return value


def artifact_digest(value: dict[str, Any], identity_field: str) -> str:
    payload = {
        key: item
        for key, item in value.items()
        if key not in {identity_field, "validation"}
    }
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def pointer_escape(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def leaf_paths(value: Any, path: str = "") -> list[str]:
    if isinstance(value, dict):
        if not value:
            return [path or "/"]
        result: list[str] = []
        for key in sorted(value):
            result.extend(leaf_paths(value[key], f"{path}/{pointer_escape(key)}"))
        return result
    if isinstance(value, list):
        if not value:
            return [path or "/"]
        result = []
        for index, item in enumerate(value):
            result.extend(leaf_paths(item, f"{path}/{index}"))
        return result
    return [path or "/"]


def validate_bundle(payload: dict[str, Any]) -> tuple[dict[str, Any] | None, int | None]:
    if "control_plane_model" in payload or payload.get("kind") == "network-control-plane-artifact":
        return None, diagnostic(
            "OC_RAW_CPM_INPUT",
            "renderer input is CPM rather than a validated canonical bundle",
            recovery="route the artifact through network-realization-model and schema validation",
        )
    if payload.get("kind") != "network-realization-bundle":
        return None, diagnostic(
            "OC_RAW_CPM_INPUT",
            "renderer input does not identify a canonical realization bundle",
            observedKind=payload.get("kind"),
        )
    validation = payload.get("validation")
    if not isinstance(validation, dict) or validation.get("valid") is not True:
        return None, diagnostic(
            "OC_RAW_CPM_INPUT",
            "canonical bundle lacks a successful digest-bound validation record",
            bundleIdentity=payload.get("bundleIdentity"),
        )
    if validation.get("artifactIdentity") != payload.get("bundleIdentity"):
        return None, diagnostic(
            "OC_RAW_CPM_INPUT",
            "bundle validation identity does not match the payload",
            bundleIdentity=payload.get("bundleIdentity"),
            validationArtifactIdentity=validation.get("artifactIdentity"),
        )
    computed_identity = artifact_digest(payload, "bundleIdentity")
    if computed_identity != payload.get("bundleIdentity"):
        return None, diagnostic(
            "OC_RAW_CPM_INPUT",
            "canonical bundle digest does not match its payload",
            bundleIdentity=payload.get("bundleIdentity"),
            computedBundleIdentity=computed_identity,
        )
    return payload, None


SEMANTIC_BINDING_KEYS = {
    "address",
    "addresses",
    "dns",
    "egress",
    "exposure",
    "firewall",
    "nat",
    "policy",
    "route",
    "routes",
    "trust",
}


def semantic_binding_path(value: Any, path: str = "/categories") -> str | None:
    if isinstance(value, dict):
        for key in sorted(value):
            child = f"{path}/{pointer_escape(key)}"
            if key.lower() in SEMANTIC_BINDING_KEYS:
                return child
            found = semantic_binding_path(value[key], child)
            if found is not None:
                return found
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found = semantic_binding_path(item, f"{path}/{index}")
            if found is not None:
                return found
    return None


def validate_binding(
    binding: dict[str, Any], bundle: dict[str, Any]
) -> tuple[dict[str, Any] | None, int | None]:
    validation = binding.get("validation")
    if (
        binding.get("kind") != "network-platform-binding-bundle"
        or binding.get("target") != "openconfig"
        or binding.get("bundleIdentity") != bundle.get("bundleIdentity")
        or binding.get("requestScope") != bundle.get("requestScope")
        or not isinstance(validation, dict)
        or validation.get("valid") is not True
        or validation.get("artifactIdentity") != binding.get("bindingIdentity")
    ):
        return None, diagnostic(
            "OC_UNVALIDATED_PLATFORM_BINDING",
            "platform binding is unvalidated or mismatched",
            bundleIdentity=bundle.get("bundleIdentity"),
            bindingIdentity=binding.get("bindingIdentity"),
        )
    computed_identity = artifact_digest(binding, "bindingIdentity")
    if computed_identity != binding.get("bindingIdentity"):
        return None, diagnostic(
            "OC_UNVALIDATED_PLATFORM_BINDING",
            "platform binding digest does not match its payload",
            bindingIdentity=binding.get("bindingIdentity"),
            computedBindingIdentity=computed_identity,
        )
    authority_path = semantic_binding_path(binding.get("categories", {}))
    if authority_path is not None:
        return None, diagnostic(
            "OC_PLATFORM_BINDING_AUTHORITY",
            "platform binding attempts to create network-semantic authority",
            bindingPath=authority_path,
        )
    return binding, None


def canonical_interfaces(bundle: dict[str, Any]) -> list[dict[str, Any]] | None:
    network = bundle.get("network")
    data = network.get("data") if isinstance(network, dict) else None
    interfaces = data.get("canonicalInterfaces") if isinstance(data, dict) else None
    if not isinstance(interfaces, list) or not interfaces:
        return None
    if not all(isinstance(item, dict) for item in interfaces):
        return None
    return interfaces


def coverage_by_destination(bundle: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = bundle.get("upstreamCoverage")
    if not isinstance(rows, list):
        return {}
    return {
        row["destinationPath"]: row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("destinationPath"), str)
    }


def build_mapping(
    bundle: dict[str, Any], rules: dict[str, Any]
) -> tuple[dict[str, Any] | None, int | None]:
    interfaces = canonical_interfaces(bundle)
    if interfaces is None:
        return None, diagnostic(
            "OC_REQUIRED_CANONICAL_FIELD_MISSING",
            "canonical interface collection is absent or empty",
            canonicalPath="/network/data/canonicalInterfaces",
        )
    rule_fields = rules.get("fields")
    if not isinstance(rule_fields, dict):
        return None, diagnostic(
            "OC_OUTPUT_WITHOUT_PROVENANCE",
            "mapping rule set has no field registry",
            ruleSet=rules.get("revision"),
        )
    for relative_path, rule in sorted(rule_fields.items()):
        if isinstance(rule, dict) and "default" in rule:
            return None, diagnostic(
                "OC_RENDERER_DEFAULT_INVENTED",
                "mapping rule attempts to supply a renderer-local default",
                canonicalRelativePath=relative_path,
                openconfigPaths=rule.get("openconfigPaths"),
            )

    upstream = coverage_by_destination(bundle)
    rendered: list[dict[str, Any]] = []
    provenance: list[dict[str, Any]] = []
    consumption: list[dict[str, Any]] = []
    output_coverage: list[dict[str, Any]] = []

    for index, interface in enumerate(interfaces):
        base = f"/network/data/canonicalInterfaces/{index}"
        identity = interface.get("identity")
        name = identity.get("name") if isinstance(identity, dict) else None
        if not isinstance(name, str) or not name:
            return None, diagnostic(
                "OC_REQUIRED_CANONICAL_FIELD_MISSING",
                "canonical interface identity.name is required",
                interfaceIndex=index,
                canonicalPath=f"{base}/identity/name",
            )
        interface_type = interface.get("type")
        iana_identity = (
            interface_type.get("ianaIdentity")
            if isinstance(interface_type, dict)
            else None
        )
        if not isinstance(iana_identity, str) or not iana_identity:
            attempted = [
                key for key in ("sourceKind", "adapterClass", "runtimeIfName")
                if key in interface
            ]
            details: dict[str, Any] = {
                "interfaceIndex": index,
                "canonicalPath": f"{base}/type/ianaIdentity",
            }
            if attempted:
                details["relatedDiagnostics"] = ["OC_RENDERER_DEFAULT_INVENTED"]
                details["forbiddenSources"] = attempted
            return None, diagnostic(
                "OC_TYPE_IDENTITY_UNMAPPED",
                "explicit canonical IANA interface identity is required",
                **details,
            )

        leaves = leaf_paths(interface)
        for leaf in leaves:
            if leaf == "/canonicalPath":
                consumption.append(
                    {
                        "canonicalPath": f"{base}{leaf}",
                        "classification": "not-applicable",
                        "authority": "openconfig-interface-mapping/v1",
                        "reason": "canonical object locator metadata",
                    }
                )
                continue
            if leaf not in rule_fields:
                return None, diagnostic(
                    "OC_CANONICAL_PATH_UNMAPPED",
                    "canonical interface path has no mapping or limitation",
                    canonicalPath=f"{base}{leaf}",
                )

        def emits(relative_path: str, openconfig_path: str) -> bool:
            rule = rule_fields.get(relative_path)
            paths = rule.get("openconfigPaths") if isinstance(rule, dict) else None
            return isinstance(paths, list) and openconfig_path in paths

        config: dict[str, Any] = {}
        if emits("/identity/name", "config/name"):
            config["name"] = name
        if emits("/type/ianaIdentity", "config/type"):
            config["type"] = iana_identity
        if emits("/description", "config/description") and isinstance(
            interface.get("description"), str
        ):
            config["description"] = interface["description"]
        if emits("/enabled", "config/enabled") and isinstance(
            interface.get("enabled"), bool
        ):
            config["enabled"] = interface["enabled"]
        if (
            emits("/mtu", "config/mtu")
            and isinstance(interface.get("mtu"), int)
            and not isinstance(interface.get("mtu"), bool)
        ):
            config["mtu"] = interface["mtu"]
        rendered_interface: dict[str, Any] = {"config": config}
        if emits("/identity/name", "name"):
            rendered_interface["name"] = name
        rendered.append(rendered_interface)

        canonical_values = {
            "/identity/name": name,
            "/type/ianaIdentity": iana_identity,
            "/description": interface.get("description"),
            "/enabled": interface.get("enabled"),
            "/mtu": interface.get("mtu"),
        }
        for relative_path, value in canonical_values.items():
            if value is None:
                continue
            rule = rule_fields.get(relative_path)
            rule_identity = rule.get("ruleIdentity") if isinstance(rule, dict) else None
            output_paths = rule.get("openconfigPaths") if isinstance(rule, dict) else None
            canonical_path = f"{base}{relative_path}"
            upstream_row = upstream.get(canonical_path)
            if (
                not isinstance(rule_identity, str)
                or not rule_identity
                or not isinstance(output_paths, list)
                or not output_paths
                or upstream_row is None
            ):
                return None, diagnostic(
                    "OC_OUTPUT_WITHOUT_PROVENANCE",
                    "mapped output lacks canonical or rule provenance",
                    canonicalPath=canonical_path,
                    openconfigPaths=output_paths,
                )
            consumption.append(
                {
                    "canonicalPath": canonical_path,
                    "classification": "consumed",
                    "ruleIdentity": rule_identity,
                }
            )
            for output_path in output_paths:
                path = f"/openconfig-interfaces:interfaces/interface/{index}/{output_path}"
                record = {
                    "bundleIdentity": bundle["bundleIdentity"],
                    "canonicalPath": canonical_path,
                    "openconfigPath": path,
                    "ruleIdentity": rule_identity,
                    "upstreamSourcePath": upstream_row.get("sourcePath"),
                    "upstreamRuleIdentity": upstream_row.get("transformationRule"),
                }
                provenance.append(record)
                output_coverage.append(
                    {
                        **record,
                        "classification": "direct",
                    }
                )

    instance = {"openconfig-interfaces:interfaces": {"interface": rendered}}
    return {
        "instance": instance,
        "fieldProvenance": provenance,
        "consumptionCoverage": consumption,
        "outputCoverage": output_coverage,
        "limitations": [],
        "mappingRuleSet": rules.get("revision"),
    }, None


def validate_yang(
    candidate: dict[str, Any],
    validator: pathlib.Path,
    bundle_identity: str,
) -> tuple[dict[str, Any] | None, int | None]:
    with tempfile.TemporaryDirectory(prefix="openconfig-render-") as directory:
        instance_path = pathlib.Path(directory) / "instance.json"
        instance_path.write_text(
            json.dumps(candidate["instance"], sort_keys=True), encoding="utf-8"
        )
        candidate_digest = hashlib.sha256(instance_path.read_bytes()).hexdigest()
        renderer_identity = (
            "network-renderer-openconfig:"
            f"{candidate.get('mappingRuleSet', 'unidentified-mapping-rules')}"
        )
        result = subprocess.run(
            [
                str(validator),
                str(instance_path),
                "--expected-instance-sha256",
                candidate_digest,
                "--bundle-identity",
                bundle_identity,
                "--renderer-identity",
                renderer_identity,
            ],
            capture_output=True,
            check=False,
            text=True,
        )
    if result.returncode != 0:
        try:
            underlying = json.loads(result.stderr)
        except json.JSONDecodeError:
            underlying = {"stderr": result.stderr}
        underlying.pop("validatedAt", None)
        if underlying.get("instanceDocument") == str(instance_path):
            underlying["instanceDocument"] = "<candidate-instance>"
        for field in ("stderr", "yanglintStderr", "yanglintStdout"):
            if isinstance(underlying.get(field), str):
                underlying[field] = underlying[field].replace(
                    str(instance_path), "<candidate-instance>"
                )
        return None, diagnostic(
            "OC_YANG_VALIDATION_FAILED",
            "candidate instance failed the pinned YANG validation gate",
            underlyingDiagnostic=underlying,
        )
    validation = json.loads(result.stdout)
    validation.pop("validatedAt", None)
    return validation, None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a validated canonical bundle to OpenConfig JSON_IETF"
    )
    parser.add_argument("bundle", type=pathlib.Path)
    parser.add_argument("--mapping-rules", required=True, type=pathlib.Path)
    parser.add_argument("--validator", required=True, type=pathlib.Path)
    parser.add_argument("--platform-binding", type=pathlib.Path)
    parser.add_argument("--peer-renderer-input", type=pathlib.Path)
    parser.add_argument("--runtime-target", help="deprecated compatibility selector")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.peer_renderer_input is not None:
        return diagnostic(
            "OC_PEER_RENDERER_CONSUMED",
            "peer renderer artifacts cannot supply OpenConfig field values",
            artifactPath=str(args.peer_renderer_input),
            targetPath="/openconfig-interfaces:interfaces/interface/*/config/mtu",
        )
    try:
        payload = load_json(args.bundle, "OC_RAW_CPM_INPUT")
        rules = load_json(args.mapping_rules, "OC_OUTPUT_WITHOUT_PROVENANCE")
    except ValueError as error:
        return diagnostic("OC_RAW_CPM_INPUT", str(error))

    bundle, status = validate_bundle(payload)
    if status is not None or bundle is None:
        return status or FAIL_CLOSED_EXIT
    if args.platform_binding is not None:
        try:
            binding_payload = load_json(
                args.platform_binding, "OC_UNVALIDATED_PLATFORM_BINDING"
            )
        except ValueError as error:
            return diagnostic("OC_UNVALIDATED_PLATFORM_BINDING", str(error))
        _binding, status = validate_binding(binding_payload, bundle)
        if status is not None:
            return status

    candidate, status = build_mapping(bundle, rules)
    if status is not None or candidate is None:
        return status or FAIL_CLOSED_EXIT
    yang_validation, status = validate_yang(
        candidate,
        args.validator,
        bundle["bundleIdentity"],
    )
    if status is not None or yang_validation is None:
        return status or YANG_FAILURE_EXIT

    accepted = {
        "status": "OK",
        "code": "OC_INSTANCE_ACCEPTED",
        "bundleIdentity": bundle["bundleIdentity"],
        **candidate,
        "yangValidation": yang_validation,
    }
    json.dump(accepted, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
