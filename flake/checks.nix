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
        touch $out
      '';

    checks.python = runCommand "albedo-python-tests" {nativeBuildInputs = [pkgs.python311];} ''
      export PYTHONDONTWRITEBYTECODE=1
      export PYTHONPATH=${runtime}/lib/albedo/albedo/priv/python
      export ALBEDO_FORMATTER_SOURCE=$PYTHONPATH
      export ALBEDO_LSP_SOURCE=$PYTHONPATH
      export ALBEDO_QUESTIONS_SOURCE=$PYTHONPATH
      python3 -m unittest discover -s ${../test} -p formatter_python_test.py -v
      python3 -m unittest discover -s ${../test} -p lazy_mcp_python_test.py -v
      python3 ${../test}/lsp_test.py -v
      python3 -m unittest discover -s ${../test} -p questions_python_test.py -v
      touch $out
    '';
  };
}
