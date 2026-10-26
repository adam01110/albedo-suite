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
    inherit (pkgs.lib) hasInfix makeBinPath;
    inherit
      (pkgs)
      # keep-sorted start
      callPackage
      runCommand
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

    withSuiteNotices = package:
      package.overrideAttrs (old: {
        meta = (old.meta or {}) // {license = pkgs.lib.licenses.mpl20;};
        postInstall =
          (old.postInstall or "")
          + ''
            doc="$out/share/doc/albedo-suite"
            mkdir -p "$doc/source"
            cp ${../../LICENSE} "$doc/LICENSE"
            cp ${../../THIRD_PARTY_NOTICES.md} "$doc/THIRD_PARTY_NOTICES.md"
            cp -r --no-preserve=mode ${../../LICENSES} "$doc/LICENSES"
            cp ${../../docs/package-sources.md} "$doc/SOURCE.md"
            cp ${albedo-git.src}/native/render/fonts/JetBrainsMono-OFL.txt "$doc/LICENSES/JetBrainsMono-OFL.txt"
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
            ln -s ${self.outPath} "$doc/source/suite"
            ln -s ${albedo-git.src} "$doc/source/upstream"
          '';
      });

    withServerSources = package:
      withSuiteNotices (package.overrideAttrs (old: {
        # Fail on upstream drift before installing editable source files.
        postPatch =
          ''
            sha256sum --check ${../../upstream/server.sha256}
            cp -r --no-preserve=mode ${../../src/server}/. .
          ''
          + (old.postPatch or "");
        doCheck = true;
        postCheck =
          (old.postCheck or "")
          + ''
            cp ${../../test/suite_codex_error_test.gleam} test/suite_codex_error_test.gleam
            cp ${../../test/suite_opencode_go_test.gleam} test/suite_opencode_go_test.gleam
            cp ${../../test/suite_questions_test.gleam} test/suite_questions_test.gleam
            cp ${../../test/suite_prompt_docs_test.gleam} test/suite_prompt_docs_test.gleam
            gleam run -m suite_prompt_docs_test
            gleam run -m suite_codex_error_test
            gleam run -m suite_opencode_go_test
            gleam run -m suite_questions_test
          '';
        postInstall =
          (old.postInstall or "")
          + ''
            wrapProgram "$out/bin/albedo-daemon" --prefix PATH : ${toolPath}
          '';
      }));

    # Zig defaults to the build host CPU, which may exceed the runtime CPU.
    withPortableUsageCore = package:
      package.overrideAttrs (old: {
        buildPhase = assert hasInfix "zig build " old.buildPhase;
          builtins.replaceStrings ["zig build "] ["zig build -Dcpu=baseline "] old.buildPhase;
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.python3];
        doInstallCheck = true;
        postInstallCheck =
          (old.postInstallCheck or "")
          + ''
            ALBEDO_USAGE_CORE="$out/bin/usage" python3 ${../../test/usage_core_test.py}
          '';
      });

    withClientSources = showDiffs: package: let
      clientSources = builtins.path {
        path = ../../src/client;
        filter = path: _: showDiffs || !(builtins.elem (baseNameOf path) ["default_diffs_test.go" "chat_test.go"]);
      };
    in
      withSuiteNotices (package.overrideAttrs (old: {
        postPatch =
          ''
            sha256sum --check ${../../upstream/client.sha256}
            cp -r --no-preserve=mode ${clientSources}/. .
            ${pkgs.lib.optionalString (!showDiffs) ''substituteInPlace cli/internal/tui/chat.go --replace-fail "DisplayFlags{Diffs: true}" "DisplayFlags{}"''}
          ''
          + (old.postPatch or "");
        postCheck =
          (old.postCheck or "")
          + ''
            go test ./internal/app ./internal/cli ./internal/webui -count=1
            go test ./internal/tui -run '^TestBase16' -count=1 -v
            go test ./internal/tui -run '^TestVim' -count=1 -v
            go test ./internal/tui -run '^TestNavigation' -count=1 -v
            go test ./internal/tui -run '^TestContext' -count=1 -v
            go test ./internal/tui ./internal/daemon -run '^(TestSuiteEscape|TestInterrupt)' -count=1 -v
            go test ./internal/tui -run '^TestOpenCodeGo' -count=1 -v
            go test ./internal/tui ./internal/daemon -run '^TestToolImages' -count=1 -v
            ${pkgs.lib.optionalString showDiffs "go test ./internal/tui -run '^TestDefaultDiffVisibility$' -count=1 -v"}
          '';
      }));

    suiteAlbedo = showDiffs:
      assert albedo-git.src.outputHash == pin.narHash;
        (albedo-git.override {
          callPackage = path: args: let
            package = callPackage path args;
            name = baseNameOf path;
          in
            if name == "server.nix"
            then withServerSources package
            else if name == "client.nix"
            then withClientSources showDiffs package
            else if name == "render.nix"
            then withSuiteNotices package
            else if name == "usage-core.nix"
            then withPortableUsageCore package
            else package;
        }).overrideAttrs (old: {
          meta = (old.meta or {}) // {license = pkgs.lib.licenses.mpl20;};
          passthru = (old.passthru or {}) // {web = self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-web;};
          buildCommand =
            old.buildCommand
            + ''
              wrapProgram $out/bin/albedo --set-default ALBEDO_WEB_DIST ${self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-web}
            '';
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
