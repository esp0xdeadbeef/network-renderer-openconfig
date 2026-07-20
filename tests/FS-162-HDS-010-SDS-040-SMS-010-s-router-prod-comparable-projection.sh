#!/usr/bin/env bash
# GAMP-ID: FS-162-HDS-010-SDS-040-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build ".#checks.${system}.fs230-posture-contract" --no-link >/dev/null

echo "PASS FS-162-HDS-010-SDS-040-SMS-010: one canonical FS-230 bundle identity supplies the NixOS, CLAB, and OpenConfig peer comparison"
