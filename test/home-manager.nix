{
  # keep-sorted start
  inputs,
  pkgs,
  suitePackages,
  # keep-sorted end
}: let
  inherit (pkgs) lib;

  module = import ../nix/home-manager.nix {inherit suitePackages;};
  stubAlbedo = pkgs.writeShellScriptBin "albedo" "exit 0";

  mkHome = settings:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home.username = "fixture";
          home.homeDirectory = "/tmp/albedo-suite-home";
          home.stateVersion = "26.05";
          programs.albedo = {package = stubAlbedo;} // settings;
        }
      ];
    };

  disabled = mkHome {};
  minimal = mkHome {enable = true;};
  configured = mkHome {
    enable = true;
    activeProvider = "fixture";
    providers.fixture = {
      extension = "codex";
      model = "fixture";
      protocol = "responses";
    };
    environment.PUBLIC_VALUE = "spaces and $literal";
    mcp = {
      enable = true;
      servers.fixture = {
        command = "/bin/fixture";
        description = "Load for fixture documentation.";
        idleTimeoutMs = 0;
        secretFiles.API_KEY = "/run/user/12345/albedo-secret";
      };
    };
    formatter.enable = true;
    linter.enable = true;
    lsp.enable = true;
  };
  iconified = mkHome {
    enable = true;
    icons.brand = "*";
  };
  unknownActiveProvider = mkHome {
    enable = true;
    activeProvider = "missing";
  };
  conflictingEnableFlag = mkHome {
    enable = true;
    settings.enabled.formatter = true;
  };
  conflictingLinterEnableFlag = mkHome {
    enable = true;
    settings.enabled.linter = true;
  };
  conflictingLspEnableFlag = mkHome {
    enable = true;
    settings.enabled.lsp = true;
  };
  conflictingMcpEnableFlag = mkHome {
    enable = true;
    settings.enabled.mcp = true;
  };
  invalidEnvironmentName = mkHome {
    enable = true;
    environment."BAD-NAME" = "x";
  };
  defaultIdleServer = mkHome {
    enable = true;
    mcp.servers.plain.command = "/bin/fixture";
  };
  nixPathSecret = mkHome {
    enable = true;
    mcp.servers.fixture = {
      command = "/bin/fixture";
      secretFiles.KEY = ./home-manager.nix;
    };
  };
  storePathSecret = mkHome {
    enable = true;
    mcp.servers.fixture = {
      command = "/bin/fixture";
      secretFiles.KEY = "${stubAlbedo}/bin/albedo";
    };
  };

  assertionsPass = home: let
    assertions = home.config.assertions;
    checked =
      builtins.tryEval (builtins.deepSeq assertions
        (lib.all (item: item.assertion) assertions));
  in
    checked.success && checked.value;

  secretTypesAccept = home:
    (builtins.tryEval (builtins.deepSeq home.config.programs.albedo.mcp.servers true)).success;
in
  lib.runTests {
    # keep-sorted start block=yes newline_separated=yes
    testConfiguredConfigurationIsValid = {
      expr = assertionsPass configured;
      expected = true;
    };

    testConflictingEnableFlagsAreRejected = {
      expr =
        !assertionsPass conflictingEnableFlag
        && !assertionsPass conflictingLinterEnableFlag
        && !assertionsPass conflictingLspEnableFlag
        && !assertionsPass conflictingMcpEnableFlag;
      expected = true;
    };

    testDefaultRuntimeDirectory = {
      expr = minimal.config.home.sessionVariables.ALBEDO_HOME == "/tmp/albedo-suite-home/.local/share/albedo";
      expected = true;
    };

    testDisabledIsInert = {
      expr =
        !(disabled.config.home.activation ? configureAlbedoSettings)
        && !(disabled.config.home.sessionVariables ? ALBEDO_HOME);
      expected = true;
    };

    testFinalPackageIsInstalled = {
      expr = lib.elem (toString configured.config.programs.albedo.finalPackage) (map toString configured.config.home.packages);
      expected = true;
    };

    testFinalPackageIsReadOnly = {
      expr = configured.options.programs.albedo.finalPackage.readOnly;
      expected = true;
    };

    testIconsAreOptIn = {
      expr = !(minimal.config.programs.albedo.environment ? ALBEDO_ICONS_FILE);
      expected = true;
    };

    testIconsWriteTheirFile = {
      expr = lib.hasSuffix "-albedo-icons.json" iconified.config.programs.albedo.environment.ALBEDO_ICONS_FILE;
      expected = true;
    };

    testInstructionsAreOptIn = {
      expr = !(minimal.config.home.file ? ".agents/APPEND_SYSTEM.md");
      expected = true;
    };

    testInvalidEnvironmentNameIsRejected = {
      expr = !assertionsPass invalidEnvironmentName;
      expected = true;
    };

    testLinterIsOptIn = {
      expr = !minimal.config.programs.albedo.linter.enable;
      expected = true;
    };

    testLspIsOptIn = {
      expr = !minimal.config.programs.albedo.lsp.enable;
      expected = true;
    };

    testMcpIdleCleanupDefaultsToOneMinute = {
      expr = minimal.config.programs.albedo.mcp.idleTimeoutMs;
      expected = 60000;
    };

    testMcpServerIdleTimeoutIsOptional = {
      expr =
        configured.config.programs.albedo.mcp.servers.fixture.idleTimeoutMs
        == 0
        && defaultIdleServer.config.programs.albedo.mcp.servers.plain.idleTimeoutMs == null;
      expected = true;
    };

    testMinimalConfigurationIsValid = {
      expr = assertionsPass minimal;
      expected = true;
    };

    testProvidersDocumentIsConditional = {
      expr =
        lib.hasInfix "config.json" configured.config.home.activation.configureAlbedoSettings.data
        && !lib.hasInfix "config.json" minimal.config.home.activation.configureAlbedoSettings.data;
      expected = true;
    };

    testStorePathsAsSecretsAreRejected = {
      expr =
        !secretTypesAccept nixPathSecret
        && !secretTypesAccept storePathSecret;
      expected = true;
    };

    testUnknownActiveProviderIsRejected = {
      expr = !assertionsPass unknownActiveProvider;
      expected = true;
    };
    # keep-sorted end
  }
