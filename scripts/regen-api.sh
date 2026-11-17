#!/usr/bin/env bash
# Regenerate API files derived from the overlay's docs/openapi.yaml.
#
# Upstream's cli/tools/apigen runs on a scratch copy of the pinned source with
# the suite contract; generated files that the overlay replaces are copied back,
# which also resolves update conflicts in them. Merge openapi.yaml by hand first.
set -euo pipefail
cd "$(dirname "$0")/.."
contract=src/server/docs/openapi.yaml
if grep -qE '^(<<<<<<<|>>>>>>>) ' "$contract"; then
  echo "resolve conflict markers in $contract first" >&2
  exit 1
fi
source_path=$(nix eval --no-update-lock-file --raw .#albedo-defaults.server.src.outPath)
scratch=$(mktemp -d)
trap 'chmod -R u+w "$scratch" && rm -rf "$scratch"' EXIT
cp -r --no-preserve=mode "$source_path/." "$scratch"
cp "$contract" "$scratch/docs/openapi.yaml"
nix shell --no-update-lock-file --inputs-from . nixpkgs#go --command \
  env CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-mod=mod go -C "$scratch/cli/tools/apigen" run .
for pair in \
  "cli/internal/daemon/protocol/api.gen.go:src/client" \
  "cli/internal/daemon/protocol/digest.gen.go:src/client" \
  "src/albedo/daemon/api_digest.gleam:src/server"; do
  name=${pair%%:*}
  overlay=${pair#*:}/$name
  if [ -f "$overlay" ]; then
    cp "$scratch/$name" "$overlay"
    echo "regenerated $overlay"
  fi
done
