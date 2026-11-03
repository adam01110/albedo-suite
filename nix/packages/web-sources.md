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
separately when copying only the assets, using a source-delivery method permitted
by AGPL section 6. Source is governed by AGPL-3.0-only with the Classpath exception
except for the components identified in `THIRD_PARTY_NOTICES.md`. The license and
exception are in `LICENSE`. The exception permits independent linked modules to
keep their own licenses; changes to Albedo remain covered. Original MPL-covered
portions retain their MPL notices and source requirements, including the
separately licensed madoromi colours. The suite repository retains historical
MPL and WTFPL texts in its `LICENSES/` directory.

For modified versions supporting remote network interaction, AGPL section 13
requires a prominent, no-charge network offer of the exact Corresponding Source
to remote users. Operators must provide this for their deployed version,
including any changes and required build materials. The local source link is
not a network source endpoint or a user-facing offer; these packaging notices
do not implement one.

License, copyright and notice files from the npm build tree are retained in
`dependency-notices/` with their package-relative paths. This collection includes
build-time packages as well as browser dependencies; it does not relicense them.
