# Albedo web client source and licenses

The adjacent `source` link references the immutable, pristine Albedo source used
for this build. The web client's preferred source form is `source/web/`;
`source/nix/packages/web.nix` contains upstream's build recipe and
`source/web/package-lock.json` identifies its npm dependencies. The suite does
not modify the web source. The suite packaging recipe is available from
<https://tangled.org/adam0.dev/albedo-suite> in `nix/modules/web.nix`.

The minified browser assets are executable form. The covered source remains
available through this package's Nix store reference; retain it when distributing
the package closure, or provide the corresponding source and these notices
separately when copying only the assets. Source is governed by MPL-2.0 except for
the components identified in `THIRD_PARTY_NOTICES.md`. The MPL text is in `LICENSE`.

License, copyright and notice files from the npm build tree are retained in
`dependency-notices/` with their package-relative paths. This collection includes
build-time packages as well as browser dependencies; it does not relicense them.
