{
  # keep-sorted start
  inputs,
  self,
  # keep-sorted end
  ...
}: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) runCommand;

    homeManagerFailures = import ../test/home-manager.nix {inherit inputs pkgs suitePackages;};

    suitePackages = self.packages.${pkgs.stdenv.hostPlatform.system};
    runtime = suitePackages.albedo-defaults;
  in {
    checks.helpers = runCommand "albedo-helper-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export PYTHONDONTWRITEBYTECODE=1
      export ALBEDO_CONFIGURE=${suitePackages.albedo-configure}/bin/albedo-configure
      export ALBEDO_MCP_LAUNCHER=${suitePackages.albedo-mcp-launcher}/bin/albedo-mcp-launcher
      python3 -m unittest discover -s ${../test} -p helpers_test.py -v
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
      python3 ${../scripts/test-e2e.py} --source ${runtime.server.src} --suite ${../.} --package ${runtime} --case opencode_go_e2e_test.py
      touch $out
    '';

    checks.native-mcp = runCommand "albedo-native-mcp-tests" {nativeBuildInputs = [pkgs.beam29Packages.erlang];} ''
      cp ${../src/server/src/albedo/harness/extensions/mcp/albedo_mcp.erl} albedo_mcp.erl
      cp -r ${../test/fixtures/native}/. .
      erlc -Werror -o . *.erl
      erl -noshell -pa . -eval 'lazy_mcp_native_tests:run(), halt().'
      touch $out
    '';

    checks.package-layout = assert pkgs.lib.hasInfix "--no-preserve=mode" runtime.server.postPatch;
    assert pkgs.lib.hasInfix "--no-preserve=mode" runtime.client.postPatch;
      runCommand "albedo-package-layout" {} ''
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_formatter.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_lsp.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_plugins/lsp.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_plugins/questions.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_rtk.py
        test -f ${runtime}/lib/albedo/albedo/priv/python/albedo_fff.mjs
        test -x ${suitePackages.albedo-fff}/bin/albedo-fff
        touch $out
      '';

    checks.python = runCommand "albedo-python-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export PYTHONDONTWRITEBYTECODE=1
      export PYTHONPATH=${runtime}/lib/albedo/albedo/priv/python
      export ALBEDO_FORMATTER_SOURCE=$PYTHONPATH
      export ALBEDO_LSP_SOURCE=$PYTHONPATH
      export ALBEDO_QUESTIONS_SOURCE=$PYTHONPATH
      export ALBEDO_RTK_SOURCE=$PYTHONPATH
      export ALBEDO_FFF_SOURCE=$PYTHONPATH
      export ALBEDO_FFF_COMMAND=${suitePackages.albedo-fff}/bin/albedo-fff
      export PATH=${pkgs.rtk}/bin:${pkgs.ripgrep}/bin:${pkgs.python311Packages.pytest}/bin:$PATH
      export ALBEDO_PYTHON_SOURCE=$PYTHONPATH
      python3 -m unittest discover -s ${../test} -p formatter_python_test.py -v
      python3 -m unittest discover -s ${../test} -p lazy_mcp_python_test.py -v
      python3 ${../test}/lsp_test.py -v
      python3 -m unittest discover -s ${../test} -p questions_python_test.py -v
      python3 -m unittest discover -s ${../test} -p rtk_python_test.py -v
      python3 -m unittest discover -s ${../test} -p rtk_e2e_test.py -v
      python3 ${../test}/fff_test.py -v
      touch $out
    '';
  };
}
