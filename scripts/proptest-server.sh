#!/usr/bin/env bash
# Run the server property tests (test/proptest) in an overlay tree.
#
#   scripts/overlay-tree.sh server DIR            # once, under the CPU lock
#   scripts/proptest-server.sh DIR [module...]    # every run; light
#
# qcheck and the dependencies the daemon lacks are pinned by Hex checksum and
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
done <<'EOF'
qcheck 1.0.5 d27c12074776ec95f082ee56e0fc74685506b6ee26176f194d10f0322a39ac11
gleam_regexp 1.1.1 9c215c6ca84a5b35bb934a9b61a9a306ec743153be2b0425a0d032e477b062a9
gleam_yielder 1.1.0 8e4e4ecfa7982859f430c57f549200c7749823c106759f4a19a78aea6687717a
prng 6.0.0 7fe3879e13150248bd370469205ed07b9404dd90670febb8cd0e7643707c420e
EOF
scripts/overlay-tree.sh sync server "$dir" >/dev/null
cp test/proptest/* "$tree/test/"
if [ $# -eq 0 ]; then
  for file in test/proptest/*_prop.gleam; do
    name=${file##*/}
    set -- "$@" "${name%.gleam}"
  done
fi
"$dir/shell" bash -c 'status=0; for module; do echo "== $module"; gleam run -m "$module" || status=1; done; exit $status' bash "$@"
