_: {
  perSystem = {pkgs, ...}: {
    packages.albedo-fff = pkgs.callPackage ../nix/packages/fff.nix {};
  };
}
