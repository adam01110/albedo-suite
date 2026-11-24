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
    linter = {
      enable = mkEnableOption "temporary explicit read-only linting with files.check()";
      settings = mkOption {
        type = types.attrsOf jsonFormat.type;
        default = {};
        description = "Public linter argv commands, output parsers and file chains. Tracking is local files.write/edit only.";
      };
    };
  };
}
