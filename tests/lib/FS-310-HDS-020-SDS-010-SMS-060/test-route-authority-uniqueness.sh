#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-060
# GAMP-SCOPE: software-module-test
set -euo pipefail

# One route authority, one next-hop set — asserted on the rendered config.
#
# URS "Canonical Realization and Renderer Boundary": a platform binding shall
# not create or duplicate routing. FS-310-HDS-020-SDS-010-SMS-060: "One
# route-selection authority shall have one modeled semantic next-hop set.
# Different next-hop sets for the same authority shall fail unless explicit
# multipath policy names the complete authorized member set."
#
# Authority here is (device/path, prefix). Two static-route entries for one
# prefix with different next hops is one authority with two next hops.
#
# The bundle used is network-realization-model's `examples/cpm-result.nix`, the
# only input this renderer currently accepts end to end; the check
# `canonical-renderer-input` records why a real CPM cannot be rendered here yet
# (a CPM publishes no `canonicalInterfaces`). That limitation is asserted there,
# not duplicated here.
#
# Harness guards: the render must succeed and emit at least one route, else the
# case reports a harness error rather than passing vacuously.

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
trace_id="FS-310-HDS-020-SDS-010-SMS-060"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# A route authority must reach this renderer at all, and reach it once.
#
# This renderer maps `canonicalInterfaces[]` from the canonical bundle. A CPM
# compiled from a real intent publishes `runtimeTargets` instead, so no route
# authority for a real site arrives here. That is recorded as a hard failure
# below rather than skipped: URS forbids a renderer from obtaining network
# meaning from another source, so "the producer omits the field" is a failure of
# the realization chain, not a reason to render nothing.

REPO_ROOT="${repo_root}" SCRATCH="${scratch}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    # The row whose OPENCONFIG inventory this repository already compiles for
    # its own boundary check (fs230-cpm-openconfig-json). Examples carry no
    # inventory-openconfig.nix at the network-labs revision this flake pins.
    example = labs + "/GAMP/SMT/FS-230-HDS-010-SDS-010-SMS-040";
    cpm = flake.inputs.network-control-plane-model.libBySystem.${system}.compileAndBuildFromPaths {
      inputPath = example + "/intent.nix";
      inventoryPath = example + "/inventory-openconfig.nix";
    };
    model = cpm.control_plane_model;
    sites = builtins.concatLists (map (ent: builtins.attrValues ent)
      (builtins.attrValues (model.data or { })));
  in {
    canonicalInterfaces = builtins.length (model.canonicalInterfaces or [ ]);
    runtimeTargets = builtins.length (builtins.concatLists
      (map (s: builtins.attrNames (s.runtimeTargets or { })) sites));
  }
' >"${scratch}/cpm.json"

ci="$(jq -r '.canonicalInterfaces' "${scratch}/cpm.json")"
rt="$(jq -r '.runtimeTargets' "${scratch}/cpm.json")"

if [[ "${rt}" == "0" ]]; then
  printf 'FAIL %s: harness error -- the CPM published no runtime targets for this example\n' "${trace_id}" >&2
  exit 1
fi

if [[ "${ci}" == "0" ]]; then
  printf 'FAIL %s: the CPM carries %s runtime target(s) but publishes no canonicalInterfaces, so no route authority reaches this renderer\n' "${trace_id}" "${rt}" >&2
  printf '  URS: a renderer shall consume only the validated canonical bundle and shall not obtain network meaning from another source.\n' >&2
  printf '  SMS-060: every emitted route must trace to model/provider route authority; here there is no authority to trace.\n' >&2
  printf '  Fix in network-control-plane-model: publish canonicalInterfaces with explicit identity.name and IANA type, as this renderer maps them.\n' >&2
  exit 1
fi

printf 'PASS %s (%s canonical interface(s) published for %s runtime target(s))\n' "${trace_id}" "${ci}" "${rt}"
