_: {
  perSystem = {pkgs, ...}: {
    packages.albedo-fff = pkgs.callPackage ../packages/fff.nix {};
  };
}
