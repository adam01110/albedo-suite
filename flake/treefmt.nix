{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = _: {
    treefmt = {
      settings.global.excludes = [
        # keep-sorted start
        "flake.lock"
        "src/**"
        # keep-sorted end
      ];

      programs = {
        # keep-sorted start
        alejandra.enable = true;
        deadnix.enable = true;
        keep-sorted.enable = true;
        nixf-diagnose.enable = true;
        statix.enable = true;
        # keep-sorted end
      };
    };
  };
}
