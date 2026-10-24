{self, ...}: {
  perSystem = {pkgs, ...}: let
    inherit (builtins) readFile replaceStrings;
    inherit (pkgs.lib) getExe;
    inherit (pkgs) runCommand writeTextFile;

    monitor = writeTextFile {
      name = "albedo-monitor";
      destination = "/bin/albedo-monitor";
      executable = true;
      meta.mainProgram = "albedo-monitor";
      text = ''
        #!${pkgs.python3}/bin/python3
        ${replaceStrings ["ALBEDO_CLI = \"albedo\""] ["ALBEDO_CLI = \"${getExe self.packages.${pkgs.stdenv.hostPlatform.system}.albedo-defaults}\""] (readFile ../../scripts/albedo-monitor.py)}
      '';
    };
  in {
    packages.albedo-monitor = monitor;

    checks.monitor =
      runCommand "albedo-monitor-tests" {
        nativeBuildInputs = [pkgs.python3];
        ALBEDO_MONITOR_SOURCE = ../../scripts/albedo-monitor.py;
        PYTHONDONTWRITEBYTECODE = "1";
      } ''
        python3 -m unittest discover -s ${../../test} -p monitor_test.py -v

        # Checks the packaged entry point without a daemon.
        ${getExe monitor} --home "$TMPDIR/absent" > snapshot.json
        python3 - <<'PY'
        import json

        with open("snapshot.json", encoding="utf-8") as stream:
            snapshot = json.load(stream)

        assert snapshot["online"] is False
        assert snapshot["error"] == "daemon_not_running"
        PY

        touch "$out"
      '';
  };
}
