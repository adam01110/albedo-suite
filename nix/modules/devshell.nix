{self, ...}: {
  perSystem = {
    # keep-sorted start
    pkgs,
    system,
    # keep-sorted end
    ...
  }: let
    inherit (pkgs) mkShell;

    upstream = self.packages.${system}.albedo-defaults.server.src;
  in {
    devShells.default = mkShell {
      shellHook = ''
        mkdir -p .direnv
        ln -sfn ${upstream} .direnv/albedo-upstream
      '';
    };
  };
}
