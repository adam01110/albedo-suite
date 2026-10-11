{
  # keep-sorted start
  lib,
  pkgs,
  # keep-sorted end
  ...
}: let
  inherit
    (lib)
    # keep-sorted start
    mkEnableOption
    mkOption
    types
    # keep-sorted end
    ;

  jsonFormat = pkgs.formats.json {};
in {
  options.programs.albedo = {
    formatter = {
      enable = mkEnableOption "temporary deferred tracked-file formatting before final replies";
      settings = mkOption {
        type = types.attrsOf jsonFormat.type;
        default = {};
        description = "Public formatter argv chains and project commands. Tracking is local files.write/edit only.";
      };
    };
  };
}
