{suitePackages}: {
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
    mkEnableOption
    mkIf
    mkOption
    types
    # keep-sorted end
    ;

  jsonFormat = pkgs.formats.json {};

  cfg = config.programs.albedo;
  absoluteString = types.addCheck types.str (value: lib.hasPrefix "/" value);
  validEnvironment = environment:
    lib.all (name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null)
    (builtins.attrNames environment);
in {
  imports = [
    # keep-sorted start
    (import ./home-manager/runtime.nix {inherit suitePackages;})
    ./home-manager/formatter.nix
    ./home-manager/lsp.nix
    ./home-manager/mcp.nix
    ./home-manager/providers.nix
    # keep-sorted end
  ];

  options.programs.albedo = {
    enable = mkEnableOption "Albedo with the reusable suite integrations";
    package = mkOption {
      type = types.package;
      default =
        if cfg.showDiffs
        then suitePackages.albedo-defaults
        else suitePackages.albedo-patched;
      description = "Albedo package. showDiffs selects the default package only.";
    };
    showDiffs = mkEnableOption "diff display by default";
    home = mkOption {
      type = absoluteString;
      default = "${config.xdg.dataHome}/albedo";
      description = "Absolute runtime data directory; existing data is not migrated.";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Public CLI environment. Values are stored in Nix; do not put credentials here.";
    };
    appendInstructions = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Public instruction file appended through ~/.agents/APPEND_SYSTEM.md.";
    };
    settings = mkOption {
      type = types.attrsOf jsonFormat.type;
      default = {};
      description = "Public extension settings recursively merged into the writable runtime document.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = validEnvironment cfg.environment && !(cfg.environment ? ALBEDO_HOME);
        message = "Albedo environment names must be valid; set programs.albedo.home instead of ALBEDO_HOME.";
      }
    ];
  };
}
