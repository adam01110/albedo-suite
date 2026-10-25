#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest discover -s test -p upstream_update_test.py -v
nix fmt --no-update-lock-file -- --fail-on-change
nix build --no-update-lock-file .#albedo-defaults .#albedo-patched --no-link
nix flake check --no-update-lock-file
source_path=$(nix eval --no-update-lock-file --raw .#albedo-defaults.server.src.outPath)
package_path=$(nix build --no-update-lock-file .#albedo-defaults --no-link --print-out-paths)
cacert=$(nix eval --no-update-lock-file --raw --impure --expr '(import (builtins.getFlake (toString ./.)).inputs.nixpkgs {}).cacert.outPath')
export ERL_AFLAGS="-public_key cacerts_path '\"$cacert/etc/ssl/certs/ca-bundle.crt\"'"
python3 scripts/test-e2e.py --source "$source_path" --package "$package_path"
