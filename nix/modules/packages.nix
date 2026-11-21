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

    withServerSources = package: let
      suiteTests = [
        # keep-sorted start
        "suite_agents_glance_test"
        "suite_bridge_test"
        "suite_catalog_prices_test"
        "suite_codex_error_test"
        "suite_lazy_mcp_test"
        "suite_memory_index_test"
        "suite_opencode_go_test"
        "suite_prompt_docs_test"
        "suite_quota_discovery_test"
        "suite_quota_poll_test"
        "suite_quota_startup_test"
        "suite_quota_test"
        "suite_tool_count_test"
        "suite_usage_profile_test"
        "suite_zed_login_test"
        "suite_zed_test"
        # keep-sorted end
      ];
    in
      withSuiteNotices (package.overrideAttrs (old: let
        esqliteVersion = "0.9.0";
        esqliteChecksum = "CCF72258A4EE152EC7AD92AA9A03552EB6CA1B06B65C93AD5B6E55C302E05855";
        # The NIF builds once with the server's tools, at the shipment's own
        # path and in Gleam's rebar3 environment, so suite edits never
        # recompile sqlite3.c. The server's fixup strips the installed copy.
        esqlite = pkgs.stdenv.mkDerivation {
          pname = "esqlite-nif";
          version = esqliteVersion;
          src = pkgs.fetchurl {
            url = "https://repo.hex.pm/tarballs/esqlite-${esqliteVersion}.tar";
            sha256 = pkgs.lib.toLower esqliteChecksum;
          };
          inherit (old) nativeBuildInputs;
          unpackPhase = ''
            dir="$NIX_BUILD_TOP/${old.sourceRoot}/build/prod/erlang/esqlite"
            mkdir -p "$dir"
            tar -xOf "$src" contents.tar.gz | tar -xz -C "$dir"
            cd "$dir"
          '';
          buildPhase = ''
            export HOME="$TMPDIR/home"
            ERL_LIBS='../*/ebin' REBAR_BARE_COMPILER_OUTPUT_DIR="$PWD" REBAR_PROFILE=prod REBAR_SKIP_PROJECT_PLUGINS=true TERM=dumb \
              rebar3 bare compile --paths '../*/ebin'
          '';
          installPhase = "install -Dm755 priv/esqlite3_nif.so $out/priv/esqlite3_nif.so";
          dontFixup = true;
        };
      in {
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
        # The suite's dev build runs in a copy, so it overlaps the shipment
        # export instead of waiting for its build lock.
        buildPhase = let
          export = "\ngleam export erlang-shipment\n";
        in
          assert pkgs.lib.hasInfix export old.buildPhase;
            builtins.replaceStrings [export] [
              ''

                # Both Gleam builds copy the staged package, then run rebar3 on
                # it; without its pc hook, rebar3 compiles only the Erlang
                # modules and keeps the prebuilt NIF.
                grep -q '^  { name = "esqlite", version = "${esqliteVersion}", .*outer_checksum = "${esqliteChecksum}" },$' manifest.toml
                pushd build/packages/esqlite >/dev/null
                mv rebar.config.script rebar.config.pc.script
                echo '{ok, Config} = file:script("rebar.config.pc.script"), lists:keydelete(provider_hooks, 1, Config).' >rebar.config.script
                install -Dm755 ${esqlite}/priv/esqlite3_nif.so priv/esqlite3_nif.so
                popd >/dev/null
                suite="$TMPDIR/suite-source"
                cp -a ../.. "$suite"
                ${pkgs.lib.concatMapStrings (module: "cp ${../../test + "/${module}.gleam"} \"$suite/apps/albedo/test/${module}.gleam\"\n") suiteTests}
                # A helper a listed module imports needs no main of its own.
                cp ${../../test + "/suite_quota_fixtures.gleam"} "$suite/apps/albedo/test/suite_quota_fixtures.gleam"
                cp ${../../test/albedo_zed_login_test.erl} "$suite/apps/albedo/test/albedo_zed_login_test.erl"
                (cd "$suite/apps/albedo" && gleam build) >"$TMPDIR/suite-build.log" 2>&1 &
                suiteBuild=$!
                ${export}''
            ]
            old.buildPhase;
        postCheck =
          (old.postCheck or "")
          + ''
            status=0
            wait "$suiteBuild" || status=$?
            cat "$TMPDIR/suite-build.log"
            ((status == 0))
            # The mains run in separate VMs at once; their logs print in list order.
            pushd "$suite/apps/albedo" >/dev/null
            modules=(${toString suiteTests})
            for module in "''${modules[@]}"; do
              erl -pa build/dev/erlang/*/ebin -noshell -eval "albedo@@main:run($module)" >"$TMPDIR/$module.log" 2>&1 &
              pids+=("$!")
            done
            failed=0
            for i in "''${!modules[@]}"; do
              status=0
              wait "''${pids[$i]}" || status=$?
              echo "''${modules[$i]} exited with $status"
              cat "$TMPDIR/''${modules[$i]}.log"
              ((status == 0)) || failed=1
            done
            ((failed == 0))
            popd >/dev/null
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
      # Only cmd/albedo's tests run in this derivation; the suite adds the rest.
      # The readers of ALBEDO_TEST_DAEMON are cli/internal/storage and
      # cli/test/e2e, which no derivation here builds, so the client does not
      # wait for the server.
      assert package ? ALBEDO_TEST_DAEMON;
      assert package.subPackages == ["cmd/albedo"];
        withSuiteNotices (package.overrideAttrs (old: {
          ALBEDO_TEST_DAEMON = "";
          nativeCheckInputs = (old.nativeCheckInputs or []) ++ [pkgs.zoxide];
          postPatch =
            ''
              sha256sum --check ${../../upstream/client.sha256}
              cp -r --no-preserve=mode ${clientSources}/. .
              ${pkgs.lib.optionalString (!showDiffs) ''substituteInPlace cli/internal/tui/chat.go --replace-fail "DisplayFlags{Diffs: true}" "DisplayFlags{}"''}
              # The packages tested here must not need the daemon blanked above.
              if grep -rl ALBEDO_TEST_DAEMON cli/cmd cli/internal/{app,cli,daemon,webui,terminal,tui}; then exit 1; fi
            ''
            + (old.postPatch or "");
          # Go builds the replaced Bubble Tea module from vendor/, not third_party/.
          postConfigure =
            (old.postConfigure or "")
            + ''
              chmod u+w vendor/charm.land/bubbletea/v2
              install -m644 ${clientSources}/cli/third_party/bubbletea/cursed_renderer.go vendor/charm.land/bubbletea/v2/cursed_renderer.go
            '';
          # Tests keep buildPhase's -trimpath, so they reuse its objects instead
          # of recompiling every package without it.
          checkPhase = let
            strip = ''
              # We do not set trimpath for tests, in case they reference test assets
              export GOFLAGS=''${GOFLAGS//-trimpath/}
            '';
          in
            assert pkgs.lib.hasInfix strip old.checkPhase;
              builtins.replaceStrings [strip] [""] old.checkPhase;
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
