{
  # keep-sorted start
  lib,
  pkgs,
  # keep-sorted end
  ...
}: let
  inherit
    (lib)
    # keep-sorted start
    mkEnableOption
    mkOption
    types
    # keep-sorted end
    ;

  jsonFormat = pkgs.formats.json {};
in {
  options.programs.albedo.lsp = {
    enable = mkEnableOption "temporary local language-server diagnostics and navigation";
    settings = mkOption {
      type = types.attrsOf jsonFormat.type;
      default = {};
      description = "Public LSP server declarations. Executables and arguments are trusted, local, and started on explicit operations or files.check() for edited files.";
    };
  };
}
