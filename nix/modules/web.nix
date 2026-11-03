{self, ...}: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) buildNpmPackage;

    upstream = self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-defaults.src;
  in {
    packages.albedo-web = buildNpmPackage {
      pname = "albedo-web";
      version = "1.0.0";
      src = upstream + "/web";
      npmDepsHash = "sha256-cO7QJ6eomg2h9BpvGyCq2uLV20iAl10He9oG6w8C5jE=";
      installPhase = ''
        runHook preInstall
        cp -R dist $out
        doc="$out/share/doc/albedo-web"
        mkdir -p "$doc/dependency-notices"
        cp ${upstream}/LICENSE "$doc/LICENSE"
        cp ${upstream}/THIRD_PARTY_NOTICES.md "$doc/THIRD_PARTY_NOTICES.md"
        cp ${../packages/web-sources.md} "$doc/SOURCE.md"
        ln -s ${upstream} "$doc/source"
        find node_modules -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'notice*' -o -iname 'copyright*' \) -print0 | while IFS= read -r -d "" notice; do
          install -Dm644 "$notice" "$doc/dependency-notices/$notice"
        done
        runHook postInstall
      '';
      meta = {
        description = "Canvas web client for Albedo";
        license = import ../albedo-license.nix {inherit (pkgs) lib;};
        platforms = pkgs.lib.platforms.unix;
      };
    };
  };
}
