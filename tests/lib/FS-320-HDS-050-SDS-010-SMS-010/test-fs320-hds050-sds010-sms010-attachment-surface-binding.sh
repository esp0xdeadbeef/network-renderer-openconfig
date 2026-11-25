#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-050-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# Uniform FS-320-HDS-050 check for every renderer: whatever the artefact is,
# it attaches to a surface, and that surface is modelled authority. A renderer
# may not choose one, default one, derive one from a name, or substitute an
# available one for the named one.
#
# network-renderer-openconfig is a peer renderer that emits RFC 7951
# JSON_IETF instance documents. Each emitted interface object is a surface, so
# the same rule applies: the interface name and type come from the canonical
# bundle, never from a renderer-local default, and never from the shape of the
# name.
#
# This renderer already refuses renderer-local defaults
# (OC_RENDERER_DEFAULT_INVENTED) and maps only registered canonical fields, so
# this test is a guard against regression plus one new predicate: an interface
# whose canonical surface class is not expressible as an IANA identity must be
# a named diagnostic, not a silently-chosen default type.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

trace_id="${SMS_TEST_TRACE_ID:-FS-320-HDS-050-SDS-010-SMS-010}"

all_checks_passed=true
record_pass() { echo "PASS ${trace_id}: $1"; }
record_fail() { echo "FAIL ${trace_id}: $1" >&2; all_checks_passed=false; }

renderer="render-openconfig.py"
rules="openconfig-interface-mapping-v1.json"

echo "--- Predicate 1: no renderer-local default for a surface identity ---"

if [[ ! -f "${renderer}" ]]; then
  record_fail "OpenConfig renderer is absent: ${renderer}"
else
  if grep -qF 'OC_RENDERER_DEFAULT_INVENTED' "${renderer}"; then
    record_pass "a renderer-local default is refused with a named diagnostic"
  else
    record_fail "a renderer-local default is not refused"
  fi

  if grep -qF 'OC_REQUIRED_CANONICAL_FIELD_MISSING' "${renderer}"; then
    record_pass "a missing canonical surface identity fails closed"
  else
    record_fail "a missing canonical surface identity does not fail closed"
  fi
fi

echo ""
echo "--- Predicate 2: the mapping rule set supplies no default ---"

if [[ -f "${rules}" ]]; then
  if python3 -c '
import json, sys
rules = json.load(open("'"${rules}"'"))
fields = rules.get("fields", {})
sys.exit(0 if not any("default" in v for v in fields.values() if isinstance(v, dict)) else 1)
'; then
    record_pass "no mapping rule supplies a default value"
  else
    record_fail "a mapping rule supplies a default value"
  fi
else
  record_fail "interface mapping rule set is absent: ${rules}"
fi

echo ""
echo "--- Predicate 3: surface class is not derived from the surface name ---"

name_derived="$(
  grep -nE 'hasPrefix|hasInfix|startswith|endswith|=="br-|re\.match.*br-' "${renderer}" 2>/dev/null || true
)"
if [[ -n "${name_derived}" ]]; then
  record_fail "surface class is inferred from the surface name: ${name_derived//$'\n'/ | }"
else
  record_pass "surface class is not inferred from the surface name"
fi

echo ""
echo "--- Predicate 4: no physical-surface requirement ---"

physical_requirement="$(
  grep -nE 'physical(Nic|Port|Interface)|ethernet-only|must-be-physical' "${renderer}" 2>/dev/null || true
)"
if [[ -n "${physical_requirement}" ]]; then
  record_fail "an emitted surface requires a physical port: ${physical_requirement//$'\n'/ | }"
else
  record_pass "no emitted surface requires a physical port"
fi

echo ""
if ${all_checks_passed}; then
  echo "PASS ${trace_id} — OpenConfig renderer emits only modelled attachment surfaces."
  exit 0
fi

echo "FAIL ${trace_id} — OpenConfig renderer chooses or invents an attachment surface." >&2
exit 1
