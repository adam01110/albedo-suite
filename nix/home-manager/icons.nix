{
  # keep-sorted start
  config,
  lib,
  pkgs,
  # keep-sorted end
  ...
}: let
  inherit
    (lib)
    # keep-sorted start
    mkIf
    mkOption
    types
    # keep-sorted end
    ;

  jsonFormat = pkgs.formats.json {};

  cfg = config.programs.albedo;
in {
  options.programs.albedo.icons = mkOption {
    type = types.attrsOf types.str;
    default = {};
    example = {
      brand = "*";
      callFailed = "x";
    };
    description = "TUI icons by name, each one terminal cell wide; omitted names keep upstream's. The CLI validates names and widths at startup. See docs/configuration.md#terminal-icons.";
  };

  # The CLI reads the generated file through ALBEDO_ICONS_FILE.
  config = mkIf (cfg.enable && cfg.icons != {}) {
    programs.albedo.environment.ALBEDO_ICONS_FILE = toString (jsonFormat.generate "albedo-icons.json" cfg.icons);
  };
}
