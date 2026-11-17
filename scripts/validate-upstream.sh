#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Unresolved --apply-conflicts output must not reach a build.
if grep -rlIE --exclude-dir=__pycache__ '^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>) ' src test; then
  echo "conflict markers remain in the files above" >&2
  exit 1
fi
python3 -m unittest discover -s test -p upstream_update_test.py
nix fmt --no-update-lock-file -- --fail-on-change
nix build --no-update-lock-file .#albedo-defaults .#albedo-patched --no-link
nix flake check --no-update-lock-file --keep-going
package_path=$(nix build --no-update-lock-file .#albedo-defaults --no-link --print-out-paths)
source_path=$(nix eval --no-update-lock-file --raw .#albedo-defaults.server.src.outPath)
cacert=$(nix eval --no-update-lock-file --raw --impure --expr '(import (builtins.getFlake (toString ./.)).inputs.nixpkgs {}).cacert.outPath')
export ERL_AFLAGS="-public_key cacerts_path '\"$cacert/etc/ssl/certs/ca-bundle.crt\"'"
# Cases the flake checks already ran against the same package are skipped.
skip=()
for case in $(grep -oP -- '--case \K\S+' nix/modules/checks.nix); do
  skip+=(--skip-case "$case")
done
python3 scripts/test-e2e.py --source "$source_path" --package "$package_path" "${skip[@]}" "$@"
