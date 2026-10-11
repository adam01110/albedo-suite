{
  perSystem = {pkgs, ...}: let
    inherit (pkgs) writeShellApplication;
  in {
    packages.albedo-configure = writeShellApplication {
      name = "albedo-configure";
      runtimeInputs = with pkgs; [
        # keep-sorted start
        coreutils
        diffutils
        jq
        sqlite
        # keep-sorted end
      ];
      text =
        pkgs.lib.replaceStrings ["@mergeSettings@"] ["${../scripts/merge-settings.jq}"]
        (builtins.readFile ../scripts/configure.sh);
    };
  };
}
