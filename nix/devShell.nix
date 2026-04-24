{
    mkShell,
    zig,
    zls,
    ghosttySrc,
}:
    mkShell {
      name = "dev";
      packages = [
        zig
        zls
      ];

      shellHook = ''
        mkdir -p zig-deps
        ln -sfn ${ghosttySrc} zig-deps/ghostty
        echo "Development environment loaded!"
        echo ""
        echo "  Zig: $(zig version)"
        echo "  Ghostty: zig-deps/ghostty -> ${ghosttySrc}"
      '';
    }
