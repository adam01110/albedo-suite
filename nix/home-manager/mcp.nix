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
  options.programs.albedo.mcp = {
    enable = mkEnableOption "MCP server support";
    lazy = mkOption {
      type = types.bool;
      default = true;
      description = "Discover and connect only explicitly selected MCP servers.";
    };
    idleTimeoutMs = mkOption {
      type = types.ints.between 0 3600000;
      default = 60000;
      description = "Lazy MCP transport idle timeout in milliseconds; zero disables cleanup. Schemas remain loaded.";
    };
    servers = mkOption {
      default = {};
      description = "Managed stdio servers. Removal does not delete previously merged runtime entries.";
      type = types.attrsOf (types.submodule {
        options = {
          command = mkOption {
            type = types.addCheck types.str (value: value != "");
            description = "Executable, not a shell command.";
          };
          args = mkOption {
            type = types.listOf types.str;
            default = [];
          };
          environment = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Public, store-visible values.";
          };
          secretFiles = mkOption {
            type = types.attrsOf (types.addCheck absoluteString (value: !lib.hasPrefix "/nix/store/" value));
            default = {};
            description = "Absolute runtime-path STRINGS. Never Nix paths or secret values; contents are read only at launch.";
          };
          runtimeInputs = mkOption {
            type = types.listOf types.package;
            default = [];
          };
          extraSettings = mkOption {
            type = types.attrsOf jsonFormat.type;
            default = {};
          };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          lib.all
          (server: validEnvironment server.environment && validEnvironment server.secretFiles)
          (builtins.attrValues cfg.mcp.servers);
        message = "MCP environment and secretFiles keys must be valid environment names.";
      }
    ];
  };
}
