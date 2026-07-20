#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "${repo_root}/tests/FS-162-HDS-010-SDS-020-SMS-010-yang-model-validation.sh"
bash "${repo_root}/tests/FS-162-HDS-010-SDS-030-SMS-010-cpm-interface-parsing-fail-closed.sh"
bash "${repo_root}/tests/FS-162-HDS-010-SDS-040-SMS-010-s-router-prod-comparable-projection.sh"
