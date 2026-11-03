# Corresponding source for packaged Albedo

This package contains Albedo code and suite modifications under the GNU Affero
General Public License v3.0 only with the Classpath exception. The exception is
extended to the suite modifications and permits linking independent modules
under their own licenses; it does not exempt modifications to Albedo itself.
The license and exception are in `LICENSE`; attribution and third-party terms
are in `THIRD_PARTY_NOTICES.md` and `LICENSES/` next to this notice. The embedded
JetBrains Mono font's OFL notice is retained in `LICENSES/JetBrainsMono-OFL.txt`.
License and notice files from the Gleam, Go or Rust dependency build trees are kept
in `dependency-notices/`, with their package-relative paths.

## Included source

The adjacent `source/` directory contains links to immutable Nix store snapshots:

- `suite`: the exact suite source, overlays, build recipes and `flake.lock` used
  for this build.
- `upstream`: the pristine Albedo source selected by that lock and recorded in
  `suite/upstream/pin.json`.

These are source inputs, not links to a moving branch or the distributor's
working directory. Keep the source links and their Nix store references when
copying or distributing the package closure. A standalone binary copied out of
that closure does not include these sources or notices: provide them separately
to its recipients.

## Rebuild

With Nix flakes enabled, change to this notice's directory and run:

```console
cd -P source/suite
nix build path:.#albedo-defaults
nix build path:.#albedo-patched
```

The first variant enables CLI diffs by default; the second retains upstream's
initial diff setting. Both use the same pinned source and suite modifications.
The lock also identifies the NUR package definitions and dependency sources;
Nix may download these dependencies when rebuilding. The suite is a sparse
source overlay: neither snapshot alone is the combined build tree. Its Nix
recipes apply the overlays and packaging hooks to the pinned upstream source.

Source code is provided under AGPL-3.0-only with the Classpath exception except
for portions identified in the notices. Original portions retained from the
previous MPL-2.0 upstream pin keep their MPL notices and source-availability
requirements; `LICENSES/albedo-MPL-2.0.txt` preserves those terms. Earlier WTFPL
terms and third-party licenses are also retained. No additional fee or permission
is required to obtain the included covered source.

## Distribution and network access

When conveying executable forms, provide their exact Corresponding Source using
a method permitted by AGPL section 6, including the build and installation
materials required by that license where applicable. Keep the source inputs,
lockfile, build recipes and applicable notices together; a moving repository
branch is not a substitute for the source of the version conveyed. Independent
modules keep their own license requirements under the Classpath exception.

For a modified version supporting remote network interaction, AGPL section 13
requires prominently offering every remote user access to that version's
Corresponding Source from a network server at no charge, through a standard or
customary copying mechanism. This includes the suite modifications and required
build materials, not merely pristine upstream source. Operators must arrange
that offer and access for the version they deploy. The local Nix store links
provided here preserve source inputs but do not implement a network source
endpoint or a prominent offer to remote users.
