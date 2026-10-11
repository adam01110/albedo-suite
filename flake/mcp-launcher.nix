_: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) writeShellApplication;
  in {
    packages.albedo-mcp-launcher = writeShellApplication {
      name = "albedo-mcp-launcher";
      runtimeInputs = [pkgs.jq];
      text =
        pkgs.lib.replaceStrings
        ["@env@" "@launchConfig@"]
        ["${pkgs.coreutils}/bin/env" "${../scripts/validate-launch.jq}"]
        (builtins.readFile ../scripts/mcp-launcher.sh);
    };
  };
}
