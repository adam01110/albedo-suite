#!/usr/bin/env bash
# Run the server property tests (test/proptest) in an overlay tree.
#
#   scripts/overlay-tree.sh server DIR            # once, under the CPU lock
#   scripts/proptest-server.sh DIR [module...]    # every run; light
#
# qcheck and the dependencies the daemon lacks are pinned by Hex checksum in
# test/proptest/hex-packages.txt, which the server check also reads, and
# unpacked into the tree's test/ directory, so no manifest changes. The tree's
# test/ is only compiled for `gleam run`/`gleam test`, never for the package.
# PROPTEST_COUNT sets cases per property and PROPTEST_SEED fixes the seed.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=$(realpath -m "${1:?usage: proptest-server.sh DIR [module...]}")
shift
[ -f "$dir/.tree" ] || { echo "no tree: run scripts/overlay-tree.sh server $dir" >&2; exit 2; }
tree=$(cat "$dir/.tree")
cache=${XDG_CACHE_HOME:-$HOME/.cache}/albedo-suite/hex
mkdir -p "$cache"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
while read -r name version sha; do
  tarball=$cache/$name-$version.tar
  if [ ! -f "$tarball" ]; then
    curl -fsSL -o "$tarball.part" "https://repo.hex.pm/tarballs/$name-$version.tar"
    mv "$tarball.part" "$tarball"
  fi
  echo "$sha  $tarball" | sha256sum -c --quiet
  mkdir -p "$work/$name"
  tar -xOf "$tarball" contents.tar.gz | tar -xz -C "$work/$name" src
  # Hex tarballs also ship generated Erlang; only sources and FFI are copied.
  (cd "$work/$name/src" && find . \( -name '*.gleam' -o -name '*_ffi.erl' \) -print0 |
    xargs -0 -I{} install -Dm644 {} "$tree/test/{}")
done <test/proptest/hex-packages.txt
scripts/overlay-tree.sh sync server "$dir" >/dev/null
cp test/proptest/* "$tree/test/"
if [ $# -eq 0 ]; then
  for file in test/proptest/*_prop.gleam; do
    name=${file##*/}
    set -- "$@" "${name%.gleam}"
  done
fi
"$dir/shell" bash -c 'status=0; for module; do echo "== $module"; gleam run -m "$module" || status=1; done; exit $status' bash "$@"
