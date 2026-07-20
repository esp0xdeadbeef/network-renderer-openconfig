#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${OC_RENDERER:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
  cd "$repo_root"
  system="$(nix eval --impure --raw --expr builtins.currentSystem)"
  nix build ".#checks.${system}.canonical-interface-negatives" --no-link
  exit 0
fi

: "${OC_RENDERER:?}"
: "${OC_JQ:?}"
: "${OC_VALID_BUNDLE:?}"
: "${OC_RAW_CPM:?}"
: "${OC_MISSING_NAME:?}"
: "${OC_UNMAPPED_PATH:?}"
: "${OC_MISSING_TYPE:?}"
: "${OC_MISSING_ENABLED:?}"
: "${OC_DEFAULT_RULES:?}"
: "${OC_MISSING_PROVENANCE_RULES:?}"
: "${OC_INVALID_YANG_RULES:?}"
: "${OC_SEMANTIC_BINDING:?}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

recovery_assertion() {
  local case_id="$1"
  "$OC_RENDERER" "$OC_VALID_BUNDLE" >"${case_id}.recovery.stdout" \
    2>"${case_id}.recovery.stderr"
  "$OC_JQ" -e '
    .code == "OC_INSTANCE_ACCEPTED"
    and .status == "OK"
    and .yangValidation.code == "OC_YANG_VALIDATION_PASS"
    and (.fieldProvenance | length) > 0
    and (.outputCoverage | length) == (.fieldProvenance | length)
  ' "${case_id}.recovery.stdout" >/dev/null
  test ! -s "${case_id}.recovery.stderr"
}

expect_failure() {
  local case_id="$1"
  local expected_exit="$2"
  local expected_code="$3"
  shift 3

  if "$OC_RENDERER" "$@" >"${case_id}.stdout" 2>"${case_id}.stderr"; then
    echo "FAIL: ${case_id} unexpectedly succeeded" >&2
    exit 1
  else
    local observed_exit="$?"
  fi

  if [ "$observed_exit" -ne "$expected_exit" ]; then
    echo "FAIL: ${case_id} expected exit ${expected_exit}, observed ${observed_exit}" >&2
    cat "${case_id}.stderr" >&2
    exit 1
  fi
  if [ -s "${case_id}.stdout" ]; then
    echo "FAIL: ${case_id} emitted accepted stdout" >&2
    exit 1
  fi
  "$OC_JQ" -e --arg code "$expected_code" '
    .code == $code and .status == "NOT_OK"
  ' "${case_id}.stderr" >/dev/null

  cp "${case_id}.stderr" "${case_id}.first.stderr"
  if "$OC_RENDERER" "$@" >"${case_id}.second.stdout" \
    2>"${case_id}.second.stderr"; then
    echo "FAIL: ${case_id} deterministic rerun unexpectedly succeeded" >&2
    exit 1
  else
    local second_exit="$?"
  fi
  test "$second_exit" -eq "$expected_exit"
  test ! -s "${case_id}.second.stdout"
  cmp "${case_id}.first.stderr" "${case_id}.second.stderr"

  recovery_assertion "$case_id"
}

expect_failure OC-EMIT-N1 2 OC_RAW_CPM_INPUT "$OC_RAW_CPM"
"$OC_JQ" -e '
  .recovery == "route the artifact through network-realization-model and schema validation"
' OC-EMIT-N1.stderr >/dev/null

expect_failure OC-EMIT-N2 2 OC_REQUIRED_CANONICAL_FIELD_MISSING \
  "$OC_MISSING_NAME"
"$OC_JQ" -e '
  .interfaceIndex == 0
  and .canonicalPath == "/network/data/canonicalInterfaces/0/identity/name"
' OC-EMIT-N2.stderr >/dev/null

expect_failure OC-EMIT-N3 2 OC_CANONICAL_PATH_UNMAPPED \
  "$OC_UNMAPPED_PATH"
"$OC_JQ" -e '
  .canonicalPath == "/network/data/canonicalInterfaces/0/ethernet/experimentalFlag"
' OC-EMIT-N3.stderr >/dev/null

expect_failure OC-EMIT-N4 2 OC_TYPE_IDENTITY_UNMAPPED \
  "$OC_MISSING_TYPE"
"$OC_JQ" -e '
  .canonicalPath == "/network/data/canonicalInterfaces/0/type/ianaIdentity"
  and (.relatedDiagnostics | index("OC_RENDERER_DEFAULT_INVENTED") != null)
  and (.forbiddenSources | index("sourceKind") != null)
' OC-EMIT-N4.stderr >/dev/null

printf '{"peer":"nixos","config":{"mtu":9000}}\n' >peer-renderer.json
expect_failure OC-EMIT-N5 2 OC_PEER_RENDERER_CONSUMED \
  "$OC_VALID_BUNDLE" --peer-renderer-input peer-renderer.json
"$OC_JQ" -e '
  .artifactPath == "peer-renderer.json"
  and .targetPath == "/openconfig-interfaces:interfaces/interface/*/config/mtu"
' OC-EMIT-N5.stderr >/dev/null

expect_failure OC-EMIT-N6 2 OC_RENDERER_DEFAULT_INVENTED \
  "$OC_MISSING_ENABLED" --mapping-rules "$OC_DEFAULT_RULES"
"$OC_JQ" -e '
  .canonicalRelativePath == "/enabled"
  and (.openconfigPaths | index("config/enabled") != null)
' OC-EMIT-N6.stderr >/dev/null

expect_failure OC-EMIT-N7 2 OC_OUTPUT_WITHOUT_PROVENANCE \
  "$OC_VALID_BUNDLE" --mapping-rules "$OC_MISSING_PROVENANCE_RULES"
"$OC_JQ" -e '
  .canonicalPath == "/network/data/canonicalInterfaces/0/mtu"
  and (.openconfigPaths | index("config/mtu") != null)
' OC-EMIT-N7.stderr >/dev/null

expect_failure OC-EMIT-N8 3 OC_YANG_VALIDATION_FAILED \
  "$OC_VALID_BUNDLE" --mapping-rules "$OC_INVALID_YANG_RULES"
"$OC_JQ" -e '
  .underlyingDiagnostic.code == "OC_YANG_VALIDATION_FAILED"
  and (.underlyingDiagnostic.yanglintStderr | contains("config/name"))
' OC-EMIT-N8.stderr >/dev/null

expect_failure OC-MAP-N7 2 OC_PLATFORM_BINDING_AUTHORITY \
  "$OC_VALID_BUNDLE" --platform-binding "$OC_SEMANTIC_BINDING"
"$OC_JQ" -e '
  .bindingPath == "/categories/interfaceIdentity/0/routes"
' OC-MAP-N7.stderr >/dev/null

echo "PASS FS-162-HDS-010-SDS-010-SMS-010"
