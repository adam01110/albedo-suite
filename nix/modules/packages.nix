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
      # The property suites run with the suite tests, at few cases each.
      propertyModules = map (pkgs.lib.removeSuffix ".gleam") (builtins.filter (pkgs.lib.hasSuffix "_prop.gleam") (builtins.attrNames (builtins.readDir ../../test/proptest)));
      propertySources = pkgs.lib.fileset.toSource {
        root = ../../test/proptest;
        fileset = pkgs.lib.fileset.fileFilter (file: file.hasExt "gleam" || file.hasExt "erl" || file.name == "fake_mcp_record.py") ../../test/proptest;
      };
      suiteTests = [
        # keep-sorted start
        "suite_account_availability_test"
        "suite_agents_glance_test"
        "suite_bridge_test"
        "suite_catalog_prices_test"
        "suite_codex_error_test"
        "suite_lazy_mcp_test"
        "suite_memory_headings_test"
        "suite_memory_index_property_test"
        "suite_memory_index_test"
        "suite_opencode_go_test"
        "suite_prompt_docs_test"
        "suite_quota_discovery_test"
        "suite_quota_poll_test"
        "suite_quota_startup_test"
        "suite_quota_test"
        "suite_session_cost_test"
        "suite_tool_count_test"
        "suite_usage_profile_overflow_test"
        "suite_usage_profile_test"
        "suite_zed_callback_prop_test"
        "suite_zed_login_test"
        "suite_zed_prop_test"
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
        buildPhase = let
          export = "\ngleam export erlang-shipment\n";
        in
          assert pkgs.lib.hasInfix export old.buildPhase;
            builtins.replaceStrings [export] [
              ''

                # The Gleam build copies the staged package, then runs rebar3 on
                # it; without its pc hook, rebar3 compiles only the Erlang
                # modules and keeps the prebuilt NIF.
                grep -q '^  { name = "esqlite", version = "${esqliteVersion}", .*outer_checksum = "${esqliteChecksum}" },$' manifest.toml
                pushd build/packages/esqlite >/dev/null
                mv rebar.config.script rebar.config.pc.script
                echo '{ok, Config} = file:script("rebar.config.pc.script"), lists:keydelete(provider_hooks, 1, Config).' >rebar.config.script
                install -Dm755 ${esqlite}/priv/esqlite3_nif.so priv/esqlite3_nif.so
                popd >/dev/null
                ${export}''
            ]
            old.buildPhase;
        # The suite and upstream tests compile as their own package against the
        # shipment's build, with gleeunit (a dev dependency), so the workspace
        # never compiles a second time.
        postCheck =
          (old.postCheck or "")
          + ''
            lib="$TMPDIR/suite-lib"
            tests="$TMPDIR/suite-tests"
            mkdir -p "$lib" "$tests/src" "$tests/test"
            ln -s "$PWD"/build/prod/erlang/* "$lib"
            # The tests depend on the daemon and on its direct dependencies.
            grep -q '^name = "albedo"$' gleam.toml
            grep -q '^\[dependencies\]$' gleam.toml
            sed -e 's/^name = "albedo"$/name = "albedo_suite_tests"/' -e 's/^\[dependencies\]$/&\nalbedo = ">= 0.0.0"/' gleam.toml >"$tests/gleam.toml"
            # Upstream's tests only compile here, against the overlaid source;
            # the suite's copies go in after them, so a shared name keeps the suite's.
            cp -r test/. "$tests/test"
            ${pkgs.lib.concatMapStrings (module: "cp ${../../test + "/${module}.gleam"} \"$tests/test/${module}.gleam\"\n") suiteTests}
            # A helper a listed module imports needs no main of its own.
            cp ${../../test + "/suite_quota_fixtures.gleam"} "$tests/test/suite_quota_fixtures.gleam"
            cp ${../../test/albedo_zed_login_test.erl} "$tests/test/albedo_zed_login_test.erl"
            cp ${../../test/albedo_zed_prop.erl} "$tests/test/albedo_zed_prop.erl"
            cp ${../../test/albedo_zed_callback_prop.erl} "$tests/test/albedo_zed_callback_prop.erl"
            cp -r --no-preserve=mode ${propertySources}/. "$tests/test"
            # The lazy MCP properties start this server by its relative path.
            cp ${propertySources}/fake_mcp_record.py test/fake_mcp_record.py
            gleam compile-package --target erlang --package build/packages/gleeunit --out "$lib/gleeunit" --lib "$lib"
            # Upstream's property helper and qcheck are dev dependencies the
            # shipment leaves out; both test suites use them.
            for package in gleam_regexp gleam_yielder prng qcheck; do
              gleam compile-package --target erlang --package "build/packages/$package" --out "$lib/$package" --lib "$lib"
            done
            gleam compile-package --target erlang --package ../../packages/albedo_property --out "$lib/albedo_property" --lib "$lib"
            gleam compile-package --target erlang --package "$tests" --out "$lib/albedo_suite_tests" --lib "$lib"
            # The mains run in separate VMs at once; their logs print in list order.
            # PROPTEST_COUNT scales each property's cases; longer runs use
            # scripts/proptest-server.sh.
            export PROPTEST_COUNT=20
            failed=0
            run_mains() {
              local modules=("$@") pids=() status i
              for module in "''${modules[@]}"; do
                erl -pa "$lib"/*/ebin -noshell -eval "albedo@@main:run($module)" >"$TMPDIR/$module.log" 2>&1 &
                pids+=("$!")
              done
              for i in "''${!modules[@]}"; do
                status=0
                wait "''${pids[$i]}" || status=$?
                echo "''${modules[$i]} exited with $status"
                cat "$TMPDIR/''${modules[$i]}.log"
                ((status == 0)) || failed=1
              done
            }
            # The suite tests have tight deadlines, so the property VMs start
            # only after they finish.
            run_mains ${toString suiteTests}
            run_mains ${toString propertyModules}
            ((failed == 0))
          '';
        postInstall =
          (old.postInstall or "")
          + ''
            wrapProgram "$out/bin/albedo-daemon" --prefix PATH : ${toolPath}
            # Each module load otherwise probes every ebin directory on the
            # path; store paths never change, so their listings are cached,
            # while "." stays last and uncached. The cache lasts until
            # boot_code.prepare republishes the path (production, ALBEDO_PRELOAD
            # unset), so it mainly speeds test daemons (ALBEDO_PRELOAD=0) and
            # the start of production boots.
            substituteInPlace "$out/lib/albedo/entrypoint.sh" --replace-fail \
              '-eval "$PACKAGE@@main:run($PACKAGE)"' \
              '-eval "code:set_path(code:get_path() -- [\".\"], cache), code:add_pathz(\".\")" -eval "$PACKAGE@@main:run($PACKAGE)"'
            # OTP's own modules load first during VM start, before the cache,
            # so the shipment goes after them; that matches -pa only while no
            # shipped module or application shares an OTP one's name.
            # Dirs given with -pa in ERL_FLAGS or ERL_AFLAGS now precede it too.
            otp=$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
            names() { find -L "$1" -path '*/ebin/*' \( -name '*.beam' -o -name '*.app' \) -printf '%f\n' | sort -u; }
            names "$out/lib/albedo" >"$TMPDIR/shipped-names"
            names "$otp/lib" >"$TMPDIR/otp-names"
            if ! grep -Fqx lists.beam "$TMPDIR/otp-names" || ! grep -Fqx kernel.app "$TMPDIR/otp-names" \
              || ! grep -Fqx albedo@@main.beam "$TMPDIR/shipped-names" || ! grep -Fqx albedo.app "$TMPDIR/shipped-names"; then
              echo "The OTP shadowing guard found no modules to compare" >&2
              exit 1
            fi
            comm -12 "$TMPDIR/shipped-names" "$TMPDIR/otp-names" >"$TMPDIR/shadowed-names"
            if [[ -s "$TMPDIR/shadowed-names" ]]; then
              echo "Shipped modules or applications shadow OTP's:" >&2
              cat "$TMPDIR/shadowed-names" >&2
              exit 1
            fi
            substituteInPlace "$out/lib/albedo/entrypoint.sh" --replace-fail '-pa "$BASE"/*/ebin' '-pz "$BASE"/*/ebin'
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
      # Only the cmd packages' tests run in this derivation; the suite adds the rest.
      # The readers of ALBEDO_TEST_DAEMON are cli/internal/storage and
      # cli/test/e2e, which no derivation here builds, so the client does not
      # wait for the server.
      assert package ? ALBEDO_TEST_DAEMON;
      assert package.subPackages == ["cmd/albedo" "cmd/albedo-acp" "cmd/albedo-server" "cmd/albedo-tui" "cmd/albedo-web"];
        withSuiteNotices (package.overrideAttrs (old: {
          ALBEDO_TEST_DAEMON = "";
          nativeCheckInputs = (old.nativeCheckInputs or []) ++ [pkgs.zoxide];
          # Vendored modules stay pristine so NUR's vendorHash still holds; the
          # replaced Bubble Tea file is installed after configure instead.
          passthru =
            old.passthru
            // {
              overrideModAttrs = pkgs.lib.composeExtensions old.passthru.overrideModAttrs (_: _: {
                postPatch = old.postPatch or "";
              });
            };
          postPatch =
            ''
              sha256sum --check ${../../upstream/client.sha256}
              cp -r --no-preserve=mode ${clientSources}/. .
              # Test exchanges are checked against the contract the suite serves.
              install -m644 ${../../src/server/docs/openapi.yaml} docs/openapi.yaml
              ${pkgs.lib.optionalString (!showDiffs) ''substituteInPlace cli/internal/tui/chat.go --replace-fail "DisplayFlags{Diffs: true}" "DisplayFlags{}"''}
              # The packages tested here must not need the daemon blanked above.
              if grep -rl ALBEDO_TEST_DAEMON cli/cmd cli/internal/{app,cli,config,daemon,webui,terminal,tui}; then exit 1; fi
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
              # One run links each test binary once; a prefix may name tests in
              # several packages, as TestProp names every property test.
              go test ./internal/config ./internal/terminal ./internal/tui ./internal/tui/chrome -run '^(TestAccountAvailability|TestActivity|TestAgentsGlance|TestBase16|TestComposerScope|TestContext|TestOpenCodeGo|TestProp|TestProviderAvailability|TestQuota|TestSessionListCostLeftOfAge|TestSessionViewerTotalCostTopRight|TestSuiteEscape|TestSuiteInline|TestToolImages|TestTurnNotify|TestUsage|TestVim|TestZed|TestZoxide${pkgs.lib.optionalString showDiffs "|TestDefaultDiffVisibility$"})' -count=1 -v
            '';
        }));

    suiteAlbedo = {
      showDiffs,
      suiteNotices ? true,
    }:
      assert albedo-git.src.outputHash == pin.narHash;
        (albedo-git.override {
          # The suite ships neither the iMessage bridge nor the browser client.
          withPhoton = false;
          withWeb = false;
          callPackage = path: args: let
            # Builds depend on unwrapped components, never on suite notices.
            package = callPackage path (builtins.mapAttrs (_: arg: arg.unwrapped or arg) args);
            name = baseNameOf path;
            notices = component:
              if suiteNotices
              then component
              else component.unwrapped;
          in
            if name == "server.nix"
            then notices (withServerSources package)
            else if name == "client.nix"
            then notices (withClientSources showDiffs package)
            else if name == "render.nix"
            then notices (withSuiteNotices package)
            else package;
        }).overrideAttrs (old: {
          meta = (old.meta or {}) // {inherit license;};
          # The same composite without suite notices, which link the whole
          # tree, so E2E checks survive docs, test and Nix edits.
          passthru =
            (old.passthru or {})
            // pkgs.lib.optionalAttrs suiteNotices {
              withoutSuiteNotices = suiteAlbedo {
                inherit showDiffs;
                suiteNotices = false;
              };
            };
        });
  in {
    packages = {
      # keep-sorted start
      albedo-defaults = suiteAlbedo {showDiffs = true;};
      albedo-patched = suiteAlbedo {showDiffs = false;};
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
