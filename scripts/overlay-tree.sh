#!/usr/bin/env bash
# Materialize a component's patched build tree for incremental compiles.
#
#   scripts/overlay-tree.sh server [dir]   # unpack, overlay, fetch deps, build once
#   scripts/overlay-tree.sh client [dir]
#   scripts/overlay-tree.sh sync server [dir]  # recopy src/<component> after edits
#
# The tree comes from the package's own phases (checksum guard, overlay copy,
# vendored dependencies), so incremental `gleam build`/`go build` there match
# the Nix build without rebuilding every component. Run tools with
# `<dir>/shell gleam build` or `<dir>/shell go build ./...`. Overlay files that still
# hold conflict markers are replaced by pristine upstream in the tree, with a note.
set -euo pipefail
cd "$(dirname "$0")/.."
suite=$PWD
sync=false
if [ "${1-}" = sync ]; then
  sync=true
  shift
fi
component=${1:?usage: overlay-tree.sh [sync] server|client [dir]}
case $component in server | client) ;; *) echo "unknown component: $component" >&2 && exit 2 ;; esac
dir=$(realpath -m "${2:-/tmp/albedo-overlay-$component}")
case $dir/ in "$suite"/*) echo "tree must be outside the checkout" >&2 && exit 2 ;; esac
develop=(--no-update-lock-file ".#albedo-defaults.$component.unwrapped")
if [ "$component" = client ]; then
  # The client's check environment names the daemon; a tree needs none, so its
  # shell must not wait for a server that may not compile mid-merge.
  develop=(--impure --expr "((builtins.getFlake \"git+file://$suite\").packages.\${builtins.currentSystem}.albedo-defaults.client.unwrapped).overrideAttrs (_: { ALBEDO_TEST_DAEMON = \"\"; })")
fi

markers='^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>) '
sync_tree() {
  # Overlays mirror the unpacked source, which may contain the build directory.
  root=$(cat "$dir/.root")
  cp -r --no-preserve=mode "src/$component/." "$root/"
  # Unresolved files compile as pristine upstream so other owners can build.
  { grep -rlIE --exclude-dir=__pycache__ "$markers" "src/$component" || true; } | while read -r file; do
    name=${file#"src/$component/"}
    install -m644 "$(cat "$dir/.src")/$name" "$root/$name"
    echo "pristine (unresolved): $name" >&2
  done
  echo "tree: $(cat "$dir/.tree")"
}

if $sync; then
  sync_tree
  exit 0
fi

# Unpacked vendor trees are read-only.
if [ -e "$dir" ]; then chmod -R u+w "$dir"; fi
rm -rf "$dir"
mkdir -p "$dir"
# Phases run in a subshell so a failing build still leaves the tree to inspect.
nix develop "${develop[@]}" --command bash -c '
  set -e
  export NIX_BUILD_TOP="$1" TMPDIR="$1/tmp" out="$1/out" HOME="$1/home"
  mkdir -p "$TMPDIR" "$HOME"
  # Phase functions are not exported into `nix develop --command`.
  source "$stdenv/setup"
  cd "$1"
  unpackPhase
  cd "$sourceRoot"
  pwd > "$1/.tree"
  echo "$1/${sourceRoot%%/*}" > "$1/.root"
  echo "$src" > "$1/.src"
  for phase in patchPhase configurePhase buildPhase; do
    if [ -n "${!phase:-}" ]; then eval "${!phase}"; else "$phase"; fi
  done
' bash "$dir" || echo "initial build failed; syncing the overlay and leaving the tree" >&2
# `<dir>/shell <command...>` runs a command in the tree inside the build shell.
{
  echo '#!/usr/bin/env bash'
  printf 'cd %q && exec nix develop' "$suite"
  printf ' %q' "${develop[@]}"
  printf ' --command bash -c %q bash "$@"\n' 'export HOME="$(cat '"$dir"'/.tree)/../home" && cd "$(cat '"$dir"'/.tree)" && "$@"'
} >"$dir/shell"
chmod +x "$dir/shell"
sync_tree
