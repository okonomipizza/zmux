{
    mkShell,
    zig,
    zls,
}: let
  in
    mkShell {
      name = "dev";
      packages =
        [
          zig
          zls
        ];

      shellHook = ''
        echo "Development environment loaded!"
        echo ""
        echo "  Zig: $(zig version)"
      '';
    }
