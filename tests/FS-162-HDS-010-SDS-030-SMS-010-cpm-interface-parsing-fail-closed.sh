#!/usr/bin/env bash
# GAMP-ID: FS-162-HDS-010-SDS-030-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

runtime_target="esp0xdeadbeef-site-a-s-router-core-wan"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

renderer_store="$(nix build .#render-openconfig --no-link --print-out-paths)"
renderer="${renderer_store}/bin/render-openconfig"
current_cpm="$(nix build .#current-cpm-json --no-link --print-out-paths)"

run_fail_closed() {
  local cpm="$1"
  local output="$2"
  local diagnostic="$3"
  shift 3

  if "${renderer}" "${cpm}" --runtime-target "${runtime_target}" "$@" >"${output}" 2>"${diagnostic}"
  then
    echo "FAIL: parser unexpectedly emitted OpenConfig output" >&2
    exit 1
  else
    local rc="$?"
  fi

  if [[ "${rc}" -ne 2 ]]; then
    echo "FAIL: expected fail-closed exit 2, got ${rc}" >&2
    cat "${diagnostic}" >&2
    exit 1
  fi
  if [[ -s "${output}" ]]; then
    echo "FAIL: fail-closed parser wrote an instance document" >&2
    exit 1
  fi
}

run_fail_closed "${current_cpm}" "${tmp_dir}/base-output.json" "${tmp_dir}/base-diagnostic.json"

jq -e '
  .summary.unsupported as $unsupported
  | .code == "OC_CPM_PARSE_GAP_TYPE"
  and .status == "NOT_OK"
  and .summary.interfaces > 0
  and .summary.mapped > 0
  and .summary.gapped > 0
  and .summary.unsupported > 0
  and ([.interfaces[].mapped[].openconfigPath] | index("name") != null)
  and ([.interfaces[].mapped[].openconfigPath] | index("config.name") != null)
  and ([.interfaces[].mapped[].openconfigPath] | index("config.type") == null)
  and ([.interfaces[].gaps[]
    | select(
        .code == "OC_CPM_PARSE_GAP_TYPE"
        and .reason == "no-iana-identity-in-cpm"
        and .observedClassifications.sourceKind != null
        and .observedClassifications.adapterClass != null
      )] | length > 0)
  and ([.interfaces[].unsupported[]
    | select(.code == "OC_CPM_PARSE_UNSUPPORTED_FIELD")]
    | length == $unsupported)
' "${tmp_dir}/base-diagnostic.json" >/dev/null

jq --arg target "${runtime_target}" '
  (.control_plane_model.data[][] |
    .runtimeTargets[$target].effectiveRuntimeRealization.interfaces) |=
  (to_entries | .[0].value |= del(.runtimeIfName) | from_entries)
' "${current_cpm}" >"${tmp_dir}/missing-name-cpm.json"
run_fail_closed "${tmp_dir}/missing-name-cpm.json" "${tmp_dir}/missing-name-output.json" "${tmp_dir}/missing-name-diagnostic.json"
jq -e '
  [.interfaces[].gaps[]
    | select(
        .code == "OC_CPM_PARSE_GAP"
        and .openconfigPath == "name"
        and .reason == "missing-explicit-runtime-interface-name"
      )] | length == 1
' "${tmp_dir}/missing-name-diagnostic.json" >/dev/null

jq --arg target "${runtime_target}" '
  (.control_plane_model.data[][] |
    .runtimeTargets[$target].effectiveRuntimeRealization.interfaces) |=
  (to_entries | .[0].value.unsupportedOpenConfigProbe = true | from_entries)
' "${current_cpm}" >"${tmp_dir}/unsupported-field-cpm.json"
run_fail_closed "${tmp_dir}/unsupported-field-cpm.json" "${tmp_dir}/unsupported-field-output.json" "${tmp_dir}/unsupported-field-diagnostic.json"
jq -e '
  [.interfaces[].unsupported[]
    | select(
        .code == "OC_CPM_PARSE_UNSUPPORTED_FIELD"
        and (.cpmPath | endswith(".unsupportedOpenConfigProbe"))
      )] | length == 1
' "${tmp_dir}/unsupported-field-diagnostic.json" >/dev/null
jq -e '
  [.interfaces[].unsupported[]
    | select(.cpmPath | endswith(".unsupportedOpenConfigProbe"))]
  | length == 0
' "${tmp_dir}/base-diagnostic.json" >/dev/null

run_fail_closed "${current_cpm}" "${tmp_dir}/peer-output.json" "${tmp_dir}/peer-diagnostic.json" --peer-renderer-input "${tmp_dir}/forbidden-nixos-result.json"
jq -e '
  .code == "OC_CPM_PARSE_PEER_CONSUMED"
  and .status == "NOT_OK"
  and (.artifactPath | endswith("forbidden-nixos-result.json"))
' "${tmp_dir}/peer-diagnostic.json" >/dev/null

jq --arg target "${runtime_target}" '
  (.control_plane_model.data[][] |
    .runtimeTargets[$target].effectiveRuntimeRealization.interfaces) |=
  (to_entries | .[0].value.mtu = 1500 | from_entries)
' "${current_cpm}" >"${tmp_dir}/explicit-mtu-cpm.json"
run_fail_closed "${tmp_dir}/explicit-mtu-cpm.json" "${tmp_dir}/explicit-mtu-output.json" "${tmp_dir}/explicit-mtu-diagnostic.json"
jq -e '
  [.interfaces[].mapped[]
    | select(
        .openconfigPath == "config.mtu"
        and (.cpmPath | endswith(".mtu"))
      )] | length == 1
' "${tmp_dir}/explicit-mtu-diagnostic.json" >/dev/null

echo "PASS FS-162-HDS-010-SDS-030-SMS-010: real CPM parse and four fail-closed seeded negatives"
