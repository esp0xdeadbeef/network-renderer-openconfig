#!/usr/bin/env bash
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

mapfile -t tests < <(
  find "${repo_root}/tests" -maxdepth 1 -regextype posix-extended \( -type f -o -type l \) \
    -regex '.*/FS-[0-9]+-HDS-[0-9]+-SDS-[0-9]+-SMS-[0-9]+\.sh' \
    -printf '%p\n' | LC_ALL=C sort
)

for test_path in "${tests[@]}"; do
  bash "${test_path}"
done
