{suitePackages}: {
  # keep-sorted start
  config,
  lib,
  pkgs,
  # keep-sorted end
  ...
}: let
  inherit (builtins) isAttrs;
  inherit
    (lib)
    # keep-sorted start
    escapeShellArg
    escapeShellArgs
    mapAttrs
    mapAttrsToList
    mkIf
    mkOption
    recursiveUpdate
    types
    # keep-sorted end
    ;
  inherit
    (pkgs)
    # keep-sorted start
    makeWrapper
    symlinkJoin
    # keep-sorted end
    ;

  jsonFormat = pkgs.formats.json {};

  cfg = config.programs.albedo;
  userEnabled = cfg.settings.enabled or {};
  enabledMatches = name: value:
    !isAttrs userEnabled || !(userEnabled ? ${name}) || userEnabled.${name} == value;

  mkServer = name: server: let
    launchConfig = jsonFormat.generate "albedo-${name}-mcp.json" {
      inherit (server) args command environment;
      runtimePath = lib.makeBinPath server.runtimeInputs;
      secrets = server.secretFiles;
    };
  in
    recursiveUpdate server.extraSettings {
      inherit (server) description;
      args = ["${launchConfig}"];
      command = lib.getExe suitePackages.albedo-mcp-launcher;
      type = "stdio";
    };

  extensionSettings = recursiveUpdate cfg.settings {
    enabled = {
      formatter = cfg.formatter.enable;
      lsp = cfg.lsp.enable;
      mcp = cfg.mcp.enable;
    };
    formatter = cfg.formatter.settings;
    lsp = cfg.lsp.settings;
    mcp = {
      lazy = cfg.mcp.lazy;
      idleTimeoutMs = cfg.mcp.idleTimeoutMs;
      servers = mapAttrs mkServer cfg.mcp.servers;
    };
  };
  extensionsFile = jsonFormat.generate "albedo-extensions.json" extensionSettings;
  providersFile = jsonFormat.generate "albedo-config.json" {
    active = cfg.activeProvider;
    inherit (cfg) providers;
  };

  wrapped = symlinkJoin {
    name = "albedo-wrapped";
    meta.mainProgram = "albedo";
    paths = [cfg.package];
    nativeBuildInputs = [makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/albedo \
        --set ALBEDO_HOME ${escapeShellArg cfg.home} \
        ${escapeShellArgs (lib.concatLists (mapAttrsToList (name: value: ["--set" name value]) cfg.environment))}
    '';
  };
in {
  options.programs.albedo.finalPackage = mkOption {
    type = types.package;
    default = wrapped;
    readOnly = true;
    description = "Albedo package wrapped with the configured runtime directory and environment.";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = isAttrs userEnabled;
        message = "programs.albedo.settings.enabled must be an attribute set.";
      }
      {
        assertion = enabledMatches "mcp" cfg.mcp.enable && enabledMatches "formatter" cfg.formatter.enable && enabledMatches "lsp" cfg.lsp.enable;
        message = "Use programs.albedo.mcp.enable, formatter.enable and lsp.enable instead of conflicting settings.enabled values.";
      }
    ];
    home.sessionVariables.ALBEDO_HOME = cfg.home;
    home.packages = [cfg.finalPackage];
    home.file = mkIf (cfg.appendInstructions != null) {
      ".agents/APPEND_SYSTEM.md".source = cfg.appendInstructions;
    };

    # Keep writable documents and authentication state outside the Nix store.
    home.activation.configureAlbedoSettings = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run ${lib.getExe suitePackages.albedo-configure} ${escapeShellArg cfg.home} ${extensionsFile}
      ${lib.optionalString (cfg.activeProvider != null) ''
        run ${lib.getExe suitePackages.albedo-configure} ${escapeShellArg cfg.home} ${providersFile} config.json
      ''}
    '';
  };
}
