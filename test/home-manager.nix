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
        secretFiles.API_KEY = "/run/user/12345/albedo-secret";
      };
    };
    formatter.enable = true;
    lsp.enable = true;
  };
  unknownActiveProvider = mkHome {
    enable = true;
    activeProvider = "missing";
  };
  conflictingEnableFlag = mkHome {
    enable = true;
    settings.enabled.formatter = true;
  };
  conflictingLspEnableFlag = mkHome {
    enable = true;
    settings.enabled.lsp = true;
  };
  invalidEnvironmentName = mkHome {
    enable = true;
    environment."BAD-NAME" = "x";
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
    testMcpIdleCleanupDefaultsToOneMinute = {
      expr = minimal.config.programs.albedo.mcp.idleTimeoutMs;
      expected = 60000;
    };

    # keep-sorted start block=yes newline_separated=yes
    testConfiguredConfigurationIsValid = {
      expr = assertionsPass configured;
      expected = true;
    };

    testConfiguredManagesProviders = {
      expr = lib.hasInfix "config.json" configured.config.home.activation.configureAlbedoSettings.data;
      expected = true;
    };

    testConflictingEnableFlagIsRejected = {
      expr = !assertionsPass conflictingEnableFlag;
      expected = true;
    };

    testConflictingLspEnableFlagIsRejected = {
      expr = !assertionsPass conflictingLspEnableFlag;
      expected = true;
    };

    testDefaultRuntimeDirectory = {
      expr = minimal.config.home.sessionVariables.ALBEDO_HOME == "/tmp/albedo-suite-home/.local/share/albedo";
      expected = true;
    };

    testDisabledHasNoActivation = {
      expr = !(disabled.config.home.activation ? configureAlbedoSettings);
      expected = true;
    };

    testDisabledHasNoHomeVariable = {
      expr = !(disabled.config.home.sessionVariables ? ALBEDO_HOME);
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

    testInstructionsAreOptIn = {
      expr = !(minimal.config.home.file ? ".agents/APPEND_SYSTEM.md");
      expected = true;
    };

    testInvalidEnvironmentNameIsRejected = {
      expr = !assertionsPass invalidEnvironmentName;
      expected = true;
    };

    testLspIsOptIn = {
      expr = !minimal.config.programs.albedo.lsp.enable;
      expected = true;
    };

    testMinimalConfigurationIsValid = {
      expr = assertionsPass minimal;
      expected = true;
    };

    testMinimalLeavesProvidersUntouched = {
      expr = !lib.hasInfix "config.json" minimal.config.home.activation.configureAlbedoSettings.data;
      expected = true;
    };

    testNixPathSecretIsRejected = {
      expr = !secretTypesAccept nixPathSecret;
      expected = true;
    };

    testStorePathSecretIsRejected = {
      expr = !secretTypesAccept storePathSecret;
      expected = true;
    };

    testUnknownActiveProviderIsRejected = {
      expr = !assertionsPass unknownActiveProvider;
      expected = true;
    };
    # keep-sorted end
  }
