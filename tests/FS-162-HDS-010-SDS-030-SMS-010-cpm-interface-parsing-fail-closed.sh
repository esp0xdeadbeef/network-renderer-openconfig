#!/usr/bin/env bash
# GAMP-ID: FS-162-HDS-010-SDS-030-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build ".#checks.${system}.canonical-interface-negatives" --no-link

echo "PASS FS-162-HDS-010-SDS-030-SMS-010: canonical mapping negatives and recovery assertions"
