{
  # keep-sorted start
  inputs,
  self,
  # keep-sorted end
  ...
}: {
  perSystem = {pkgs, ...}: let
    inherit
      (builtins)
      # keep-sorted start
      fromJSON
      readFile
      # keep-sorted end
      ;
    inherit (pkgs.lib) makeBinPath;
    inherit
      (pkgs)
      # keep-sorted start
      callPackage
      runCommand
      symlinkJoin
      # keep-sorted end
      ;

    inherit (nur.repos.adam0) albedo-git;

    nur = import inputs.nur {
      inherit pkgs;
      nurpkgs = pkgs;
    };
    pin = fromJSON (readFile ../../upstream/pin.json);

    toolPath = makeBinPath [
      # keep-sorted start
      pkgs.rtk
      self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-fff
      # keep-sorted end
    ];

    license = import ../albedo-license.nix {inherit (pkgs) lib;};

    # Dependency notices need the build tree; suite-wide files stay out of it.
    withDependencyNotices = package:
      package.overrideAttrs (old: {
        meta = (old.meta or {}) // {inherit license;};
        postInstall =
          (old.postInstall or "")
          + ''
            doc="$out/share/doc/albedo-suite"
            mkdir -p "$doc/dependency-notices"
            for dependencies in build/packages vendor cli/vendor "''${cargoDeps-}"; do
              if [ -d "$dependencies" ]; then
                target="$doc/dependency-notices/$(basename "$dependencies")"
                (
                  cd "$dependencies"
                  find . -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'notice*' -o -iname 'copyright*' \) -print0 | while IFS= read -r -d "" notice; do
                    install -Dm644 "$notice" "$target/$notice"
                  done
                )
              fi
            done
          '';
      });

    # Whole-suite notices and the source link sit in a symlink wrapper, so
    # editing docs, tests or Nix outside a component's inputs reuses its build.
    withSuiteNotices = package: let
      unwrapped = withDependencyNotices package;
    in
      symlinkJoin {
        inherit (unwrapped) name;
        paths = [unwrapped];
        postBuild = ''
          doc="$out/share/doc/albedo-suite"
          mkdir -p "$doc/source" "$doc/LICENSES"
          cp ${../../LICENSE} "$doc/LICENSE"
          cp ${../../THIRD_PARTY_NOTICES.md} "$doc/THIRD_PARTY_NOTICES.md"
          cp -r --no-preserve=mode ${../../LICENSES}/. "$doc/LICENSES"
          cp ${../../docs/package-sources.md} "$doc/SOURCE.md"
          cp ${albedo-git.src}/native/render/fonts/JetBrainsMono-OFL.txt "$doc/LICENSES/JetBrainsMono-OFL.txt"
          ln -s ${self.outPath} "$doc/source/suite"
          ln -s ${albedo-git.src} "$doc/source/upstream"
        '';
        passthru =
          (unwrapped.passthru or {})
          // {
            inherit unwrapped;
            inherit (unwrapped) src version;
          };
        meta = unwrapped.meta // {inherit license;};
      };

    withServerSources = package:
      withSuiteNotices (package.overrideAttrs (old: {
        # The daemon builds in apps/albedo, but the overlay mirrors the whole
        # source tree, outside the writable source root. Fail on upstream drift
        # before installing editable source files.
        postPatch =
          ''
            root=../..
            test -f "$root/apps/albedo/gleam.toml"
            chmod -R u+w "$root"
            (cd "$root" && sha256sum --check ${../../upstream/server.sha256})
            cp -r --no-preserve=mode ${../../src/server}/. "$root"
          ''
          + (old.postPatch or "");
        doCheck = true;
        # The lazy MCP test drives upstream's Python fake stdio server.
        nativeCheckInputs = (old.nativeCheckInputs or []) ++ [pkgs.python3];
        postCheck =
          (old.postCheck or "")
          + ''
            cp ${../../test/suite_quota_test.gleam} test/suite_quota_test.gleam
            cp ${../../test/suite_codex_error_test.gleam} test/suite_codex_error_test.gleam
            cp ${../../test/suite_opencode_go_test.gleam} test/suite_opencode_go_test.gleam
            cp ${../../test/suite_prompt_docs_test.gleam} test/suite_prompt_docs_test.gleam
            gleam run -m suite_prompt_docs_test
            gleam run -m suite_quota_test
            gleam run -m suite_codex_error_test
            gleam run -m suite_opencode_go_test
            cp ${../../test/suite_bridge_test.gleam} test/suite_bridge_test.gleam
            gleam run -m suite_bridge_test
            cp ${../../test/suite_zed_test.gleam} test/suite_zed_test.gleam
            gleam run -m suite_zed_test
            cp ${../../test/suite_zed_login_test.gleam} test/suite_zed_login_test.gleam
            cp ${../../test/albedo_zed_login_test.erl} test/albedo_zed_login_test.erl
            gleam run -m suite_zed_login_test
            cp ${../../test/suite_catalog_prices_test.gleam} test/suite_catalog_prices_test.gleam
            gleam run -m suite_catalog_prices_test
            cp ${../../test/suite_memory_index_test.gleam} test/suite_memory_index_test.gleam
            gleam run -m suite_memory_index_test
            cp ${../../test/suite_lazy_mcp_test.gleam} test/suite_lazy_mcp_test.gleam
            gleam run -m suite_lazy_mcp_test
            cp ${../../test/suite_agents_glance_test.gleam} test/suite_agents_glance_test.gleam
            gleam run -m suite_agents_glance_test
            cp ${../../test/suite_tool_count_test.gleam} test/suite_tool_count_test.gleam
            gleam run -m suite_tool_count_test
            cp ${../../test/suite_usage_profile_test.gleam} test/suite_usage_profile_test.gleam
            gleam run -m suite_usage_profile_test
          '';
        postInstall =
          (old.postInstall or "")
          + ''
            wrapProgram "$out/bin/albedo-daemon" --prefix PATH : ${toolPath}
          '';
        # Seal after fixup rewrites the installed application.
        postFixup =
          (old.postFixup or "")
          + ''
            ALBEDO_BUILD_APP="$out/lib/albedo/albedo" erl +S 2:2 -pa "$out/lib/albedo"/*/ebin -noshell -eval 'application:ensure_all_started(crypto), {ok, nil} = albedo@lifecycle@build_identity:seal_build(unicode:characters_to_binary(os:getenv("ALBEDO_BUILD_APP"))), halt().'
          '';
      }));

    withClientSources = showDiffs: package: let
      clientSources = builtins.path {
        path = ../../src/client;
        filter = path: _: showDiffs || !(builtins.elem (baseNameOf path) ["default_diffs_test.go"]);
      };
    in
      withSuiteNotices (package.overrideAttrs (old: {
        nativeCheckInputs = (old.nativeCheckInputs or []) ++ [pkgs.zoxide];
        postPatch =
          ''
            sha256sum --check ${../../upstream/client.sha256}
            cp -r --no-preserve=mode ${clientSources}/. .
            ${pkgs.lib.optionalString (!showDiffs) ''substituteInPlace cli/internal/tui/chat.go --replace-fail "DisplayFlags{Diffs: true}" "DisplayFlags{}"''}
          ''
          + (old.postPatch or "");
        # Go builds the replaced Bubble Tea module from vendor/, not third_party/.
        postConfigure =
          (old.postConfigure or "")
          + ''
            chmod u+w vendor/charm.land/bubbletea/v2
            install -m644 ${clientSources}/cli/third_party/bubbletea/cursed_renderer.go vendor/charm.land/bubbletea/v2/cursed_renderer.go
          '';
        postCheck =
          (old.postCheck or "")
          + ''
            # The whole daemon package: a test without a name filter cannot be
            # left out of every check.
            go test ./internal/app ./internal/cli ./internal/daemon ./internal/webui -count=1
            # One run links each test binary once; every prefix names tests in one package.
            go test ./internal/terminal ./internal/tui -run '^(TestActivity|TestAgentsGlance|TestBase16|TestComposerScope|TestContext|TestOpenCodeGo|TestProviderAvailability|TestQuota|TestSessionListCostLeftOfAge|TestSessionViewerTotalCostTopRight|TestSuiteEscape|TestSuiteInline|TestToolImages|TestTurnNotify|TestUsage|TestVim|TestZed|TestZoxide${pkgs.lib.optionalString showDiffs "|TestDefaultDiffVisibility$"})' -count=1 -v
          '';
      }));

    suiteAlbedo = showDiffs:
      assert albedo-git.src.outputHash == pin.narHash;
        (albedo-git.override {
          callPackage = path: args: let
            # Builds depend on unwrapped components, never on suite notices.
            package = callPackage path (builtins.mapAttrs (_: arg: arg.unwrapped or arg) args);
            name = baseNameOf path;
          in
            if name == "server.nix"
            then withServerSources package
            else if name == "client.nix"
            then withClientSources showDiffs package
            else if name == "render.nix"
            then withSuiteNotices package
            else package;
        }).overrideAttrs (old: {
          meta = (old.meta or {}) // {inherit license;};
        });
  in {
    packages = {
      # keep-sorted start
      albedo-defaults = suiteAlbedo true;
      albedo-patched = suiteAlbedo false;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-defaults;
      # keep-sorted end
    };

    checks.source-baseline = runCommand "albedo-source-baseline" {} ''
      cd ${albedo-git.src}
      sha256sum --check ${../../upstream/server.sha256}
      sha256sum --check ${../../upstream/client.sha256}
      touch $out
    '';
  };

  flake.overlays.default = final: _: {
    inherit
      (self.packages.${final.stdenv.hostPlatform.system})
      # keep-sorted start
      albedo-configure
      albedo-defaults
      albedo-fff
      albedo-mcp-launcher
      albedo-monitor
      albedo-patched
      # keep-sorted end
      ;
  };
}
