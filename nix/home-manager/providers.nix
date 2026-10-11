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
  options.programs.albedo = {
    providers = mkOption {
      type = types.attrsOf (types.attrsOf jsonFormat.type);
      default = {};
      description = "Public named provider profiles; authentication remains runtime-managed.";
    };
    activeProvider = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Managed active profile. Null with empty providers leaves config.json untouched.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.providers == {} || cfg.activeProvider != null;
        message = "Managed Albedo profiles require activeProvider.";
      }
      {
        assertion = cfg.activeProvider == null || builtins.hasAttr cfg.activeProvider cfg.providers;
        message = "Albedo activeProvider must name a managed profile.";
      }
    ];
  };
}
