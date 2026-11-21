{
  # keep-sorted start
  inputs,
  self,
  # keep-sorted end
  ...
}: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) runCommand;

    homeManagerFailures = import ../../test/home-manager.nix {inherit inputs pkgs suitePackages;};

    suitePackages = self.packages.${pkgs.stdenv.hostPlatform.system};
    runtime = suitePackages.albedo-defaults;
    # The E2E checks build at once; letting each widen to every spare core
    # triples daemon boots, so each runs two private daemons at a time.
    e2eRunner = "python3 ${../../scripts/test-e2e.py} --source ${runtime.server.src} --suite ${../..} --package ${runtime} --exclusive-jobs 2";

    # Pinned upstream python with the suite overlay, assembled as the server
    # build assembles priv/python, without waiting for the package builds.
    pythonSources = runCommand "albedo-python-sources" {} ''
      cp -r ${runtime.server.src}/python $out
      chmod -R u+w $out
      cp -r --no-preserve=mode ${../../src/server/python}/. $out
    '';
  in {
    checks.upstream-update =
      runCommand "albedo-upstream-update-tests" {
        nativeBuildInputs = [
          # keep-sorted start
          pkgs.git
          pkgs.python311
          # keep-sorted end
        ];
      } ''
        export PYTHONDONTWRITEBYTECODE=1
        export ALBEDO_UPDATER=${../../scripts/update-upstream.py}
        export ALBEDO_SUITE_SOURCE=${../..}
        python3 -m unittest discover -s ${../../test} -p upstream_update_test.py -v
        touch $out
      '';

    checks.helpers = runCommand "albedo-helper-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export PYTHONDONTWRITEBYTECODE=1
      export ALBEDO_CONFIGURE=${suitePackages.albedo-configure}/bin/albedo-configure
      export ALBEDO_MCP_LAUNCHER=${suitePackages.albedo-mcp-launcher}/bin/albedo-mcp-launcher
      python3 -m unittest discover -s ${../../test} -p helpers_test.py -v
      touch $out
    '';

    checks.home-manager =
      if homeManagerFailures != []
      then throw "Home Manager cases failed: ${builtins.toJSON homeManagerFailures}"
      else
        runCommand "albedo-home-manager-tests" {} ''
          touch $out
        '';

    checks.opencode-go = runCommand "albedo-opencode-go-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export ERL_AFLAGS="-public_key cacerts_path '\"${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt\"'"
      ${e2eRunner} --case opencode_go_e2e_test.py
      touch $out
    '';

    checks.zed = runCommand "albedo-zed-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export ERL_AFLAGS="-public_key cacerts_path '\"${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt\"'"
      ${e2eRunner} --case zed_e2e_test.py
      touch $out
    '';

    checks.kernel-workspace = runCommand "albedo-kernel-workspace-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export ERL_AFLAGS="-public_key cacerts_path '\"${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt\"'"
      ${e2eRunner} --case kernel_workspace_e2e_test.py
      touch $out
    '';

    checks.tool-images = runCommand "albedo-tool-image-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export ERL_AFLAGS="-public_key cacerts_path '\"${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt\"'"
      ${e2eRunner} --case tool_images_e2e_test.py
      touch $out
    '';

    checks.session-cost-e2e = runCommand "albedo-session-cost-e2e-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export ERL_AFLAGS="-public_key cacerts_path '\"${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt\"'"
      ${e2eRunner} --case session_cost_e2e_test.py
      touch $out
    '';

    checks.session-cost = runCommand "albedo-session-cost-tests" {nativeBuildInputs = [pkgs.beam29Packages.erlang];} ''
      cp ${../../src/server/apps/albedo/src/albedo/usage/albedo_session_cost.erl} albedo_session_cost.erl
      cp ${../../test/session_cost_tests.erl} session_cost_tests.erl
      erlc -Werror -o . *.erl
      erl +S 2:2 -noshell -pa . -eval 'session_cost_tests:run(), halt().'
      touch $out
    '';

    checks.package-licenses = assert pkgs.lib.all (package: pkgs.lib.licenses.toSPDX package.meta.license == "AGPL-3.0-only WITH Classpath-exception-2.0") [
      # keep-sorted start
      runtime
      runtime.client
      runtime.render
      runtime.server
      suitePackages.albedo-patched
      suitePackages.albedo-patched.client
      # keep-sorted end
    ];
    assert pkgs.lib.licenses.toSPDX suitePackages.albedo-fff.meta.license == "(AGPL-3.0-only WITH Classpath-exception-2.0) AND MIT";
      runCommand "albedo-package-license-tests" {
        nativeBuildInputs = [pkgs.python311];
        ALBEDO_LICENSE_PACKAGES = builtins.toJSON {
          # keep-sorted start
          client = "${runtime.client}";
          client-patched = "${suitePackages.albedo-patched.client}";
          defaults = "${runtime}";
          fff = "${suitePackages.albedo-fff}";
          patched = "${suitePackages.albedo-patched}";
          render = "${runtime.render}";
          server = "${runtime.server}";
          # keep-sorted end
        };
      } ''
        python3 ${../../test/package_licenses_test.py}
        touch $out
      '';

    checks.package-layout = assert pkgs.lib.hasInfix "--no-preserve=mode" runtime.server.unwrapped.postPatch;
    assert pkgs.lib.hasInfix "--no-preserve=mode" runtime.client.unwrapped.postPatch;
    assert !(suitePackages ? albedo-web);
    assert !(runtime ? web);
    assert !(suitePackages.albedo-patched ? web);
      runCommand "albedo-package-layout" {} ''
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_formatter.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_lsp.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_plugins/lsp.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_rtk.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_fff.mjs
        test -x ${suitePackages.albedo-fff}/bin/albedo-fff
        # The python check tests this tree before the package exists.
        diff -r -x __pycache__ ${pythonSources} ${runtime}/lib/albedo/albedo/priv/python
        if grep -E '/[^/]*-albedo-web(-|$)' ${pkgs.closureInfo {rootPaths = [runtime suitePackages.albedo-patched];}}/store-paths; then
          echo "Suite runtime closure must not include the web UI" >&2
          exit 1
        fi
        touch $out
      '';

    checks.python =
      runCommand "albedo-python-tests" {
        nativeBuildInputs = [
          # keep-sorted start
          pkgs.beam29Packages.erlang
          pkgs.nodejs
          pkgs.python311
          pkgs.treefmt
          # keep-sorted end
        ];
      } ''
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${pythonSources}
        export ALBEDO_E2E_RUNNER=${../../scripts/test-e2e.py}
        export ALBEDO_FORMATTER_SOURCE=$PYTHONPATH
        export ALBEDO_LSP_SOURCE=$PYTHONPATH
        export ALBEDO_REMOTE_SOURCE=$PYTHONPATH
        export ALBEDO_RTK_SOURCE=$PYTHONPATH
        export ALBEDO_FFF_SOURCE=$PYTHONPATH
        export ALBEDO_FFF_COMMAND=${suitePackages.albedo-fff}/bin/albedo-fff
        export ALBEDO_FFF_ERLANG=${../../src/server/extensions/files/src/albedo_fff.erl}
        export ALBEDO_FFF_SCRIPT=$PYTHONPATH/albedo_fff.mjs
        export PATH=${pkgs.rtk}/bin:${pkgs.ripgrep}/bin:${pkgs.python311Packages.pytest}/bin:$PATH
        export ALBEDO_PYTHON_SOURCE=$PYTHONPATH
        # Each file keeps its own temporary state, so they run at once; their
        # logs print in list order.
        tests=(
          "-m unittest discover -s ${../../test} -p formatter_python_test.py -v"
          "-m unittest discover -s ${../../test} -p files_check_test.py -v"
          "${../../test}/e2e_runner_test.py -v"
          "${../../test}/prompt_context_python_test.py -v"
          "-m unittest discover -s ${../../test} -p lazy_mcp_python_test.py -v"
          "${../../test}/lsp_test.py -v"
          "${../../test}/remote_path_test.py -v"
          "${../../test}/remote_staging_test.py -v"
          "-m unittest discover -s ${../../test} -p rtk_python_test.py -v"
          "-m unittest discover -s ${../../test} -p rtk_e2e_test.py -v"
          "${../../test}/fff_test.py -v"
          "${../../test}/fff_stdio_test.py -v"
        )
        for i in "''${!tests[@]}"; do
          # shellcheck disable=SC2086
          python3 ''${tests[$i]} >"$TMPDIR/test-$i.log" 2>&1 &
          pids+=("$!")
        done
        failed=0
        for i in "''${!tests[@]}"; do
          status=0
          wait "''${pids[$i]}" || status=$?
          echo "python3 ''${tests[$i]} exited with $status"
          cat "$TMPDIR/test-$i.log"
          ((status == 0)) || failed=1
        done
        ((failed == 0))
        touch $out
      '';
  };
}
