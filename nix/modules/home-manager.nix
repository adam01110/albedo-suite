{self, ...}: {
  flake.homeManagerModules = {
    default = {pkgs, ...}: {
      imports = [
        (import ../home-manager.nix {
          suitePackages = self.packages.${pkgs.stdenv.hostPlatform.system};
        })
      ];
    };
    albedo = self.homeManagerModules.default;
  };
}
