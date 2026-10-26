# Corresponding source for packaged Albedo

This package contains MPL-2.0-covered Albedo code and suite modifications.
The license is in `LICENSE`; attribution and third-party exceptions are in
`THIRD_PARTY_NOTICES.md` and `LICENSES/` next to this notice. The embedded
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

Source code is provided under MPL-2.0 except for separately licensed components
identified in the notices. No additional fee or permission is required to obtain
the included covered source.
