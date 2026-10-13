{
  description = "zmux - a simple terminal multiplexer with persistent floating panes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    systems,
    ...
  }: let
    inherit (nixpkgs) lib;

    eachSystem = lib.genAttrs (import systems);
    pkgsFor = eachSystem (system:
      import nixpkgs {
        inherit system;
        overlays = [zig.overlays.default];
      });

    # Pin the Zig toolchain so every machine builds with the same compiler.
    # Keep this in sync with `pkgs.zls` above: zls only works against the
    # exact Zig release it was built for.
    zigVersion = "0.16.0";

    forAllSystems = f: lib.mapAttrs (system: pkgs: f pkgs) pkgsFor;
  in {
    packages = forAllSystems (pkgs: let
      # Headers live in the `dev` output and the shared object in `out`, so the
      # build is pointed at the two separately.
      ghosttyVt = pkgs.libghostty-vt;
    in {
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.zmux;

      zmux = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "zmux";
        version = "0.1.0";
        src = self;

        nativeBuildInputs = [pkgs.zigpkgs.${zigVersion}];

        # The VT layer is a C library, so the Zig build needs the headers to
        # translate and the shared object to link against.
        buildInputs = [ghosttyVt];

        dontConfigure = true;

        buildPhase = ''
          runHook preBuild
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-local-cache"
          export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
          export GHOSTTY_VT_INCLUDE_DIR="${lib.getDev ghosttyVt}/include"
          export GHOSTTY_VT_LIBRARY_DIR="${ghosttyVt}/lib"

          # Name the target explicitly. Inside the sandbox Zig cannot see a
          # system libc, so it would otherwise link against its bundled musl
          # and produce a binary whose interpreter does not exist on the host.
          # The glibc version is included because Zig otherwise assumes a
          # minimum far older than the stdenv's, which leaves symbols such as
          # pthread_create and shm_open unresolved.
          zig build \
            --prefix $out \
            -Dtarget=${pkgs.stdenv.hostPlatform.system}-${pkgs.stdenv.hostPlatform.parsed.abi.name}.${pkgs.glibc.version} \
            -Doptimize=ReleaseSafe
          runHook postBuild
        '';

        # `zig build` already installs into --prefix.
        dontInstall = true;

        # The linker records two absolute paths that only make sense outside
        # Nix: an interpreter under /lib64, and a search path that does not name
        # libghostty-vt at all. Neither is present on a stock NixOS machine, so
        # both are rewritten to point into the store.
        postFixup = ''
          patchelf \
            --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} \
            --set-rpath ${lib.makeLibraryPath [ghosttyVt]} \
            $out/bin/zmux
        '';

        meta = {
          description = "A simple terminal multiplexer with persistent floating panes";
          homepage = "https://github.com/okonomipizza/zmux";
          license = lib.licenses.mit;
          mainProgram = "zmux";
          platforms = lib.platforms.linux;
        };
      });
    });

    devShells = forAllSystems (pkgs: let
      ghosttyVt = pkgs.libghostty-vt;
    in {
      default = pkgs.mkShell {
        name = "zmux";

        packages = [
          pkgs.zigpkgs.${zigVersion}
          pkgs.zls
          ghosttyVt
        ];

        shellHook = ''
          # Point the Zig build at the VT library without hardcoding store
          # paths in build.zig.
          export GHOSTTY_VT_INCLUDE_DIR="${lib.getDev ghosttyVt}/include"
          export GHOSTTY_VT_LIBRARY_DIR="${ghosttyVt}/lib"

          echo "zmux dev shell"
          echo "  zig $(zig version)"
        '';
      };
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
