{self, ...}: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) buildNpmPackage;

    upstream = self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-defaults.src;
  in {
    packages.albedo-web = buildNpmPackage {
      pname = "albedo-web";
      version = "1.0.0";
      src = upstream + "/web";
      npmDepsHash = "sha256-J7frp32iNwe3xBuFSSAzQFzYSF2zgyaQtoCMMO/z7TU=";
      installPhase = ''
        runHook preInstall
        cp -R dist $out
        runHook postInstall
      '';
      meta = {
        description = "Canvas web client for Albedo";
        license = pkgs.lib.licenses.wtfpl;
        platforms = pkgs.lib.platforms.unix;
      };
    };
  };
}
