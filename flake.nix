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

    # The package, as a function of a package set, so that `packages` and `overlays` describe the same
    # build rather than two copies of it. An overlay is how most home-manager users prefer to install
    # something -- it makes `pkgs.zmux` exist rather than requiring an attribute path into a flake --
    # and having it call the same derivation is what keeps the two from drifting.
    mkZmux = pkgs: let
      # Headers live in the `dev` output and the shared object in `out`, so the
      # build is pointed at the two separately.
      ghosttyVt = pkgs.libghostty-vt;

      zig = pkgs.zigpkgs.${zigVersion};

      # Zig fetches its package dependencies over the network, which the build
      # sandbox does not have. This derivation runs the fetch once, with
      # network access, and exports the resulting cache; `zig build --system`
      # then resolves dependencies from it instead of dialling out.
      #
      # `--fetch` leaves each dependency as a tarball, but `--system` wants it
      # unpacked: it reads the dependency's own build.zig to find the modules
      # it exports. Unpacking here is what makes the consuming build work; a
      # cache left as tarballs fails with "package not found at <dir>".
      zmuxDeps = pkgs.stdenv.mkDerivation {
        name = "zmux-zig-deps";
        src = self;
        nativeBuildInputs = [zig];
        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
        outputHash = "sha256-23ka0ZsyNiEbYk81K9DqAHY5B5YA7bOVA6vjqYmyMs0=";
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
          # Zig 0.16 expects this directory to exist before fetching.
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"
          zig build --fetch

          cache="$ZIG_GLOBAL_CACHE_DIR/p"
          for archive in "$cache"/*.tar.gz; do
            [ -e "$archive" ] || continue
            tar xzf "$archive" -C "$cache"
            rm "$archive"
          done

          mv "$cache" $out
          runHook postBuild
        '';
      };
    in
      pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "zmux";
        version = "0.1.0";
        src = self;

        nativeBuildInputs = [zig];

        # The VT layer is a C library, so the Zig build needs the headers to
        # translate and the shared object to link against.
        buildInputs = [ghosttyVt];

        dontConfigure = true;

        buildPhase = ''
          runHook preBuild
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
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
            --system ${zmuxDeps} \
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
  in {
    packages = forAllSystems (pkgs: {
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.zmux;
      zmux = mkZmux pkgs;
    });

    # `pkgs.zmux` for anyone who prefers an overlay, which is the usual way to
    # install into home-manager: the attribute path into a flake is one more
    # thing to know, and an overlay makes zmux look like any other package.
    #
    # The zig overlay is applied inside `mkZmux` rather than assumed here.
    # `overlays.default` receives the consumer's `final`, and a nixpkgs without
    # our zig overlay does not have `zigpkgs` at all -- so the first version of
    # this produced `error: attribute 'zigpkgs' missing` for exactly the users
    # the overlay is for.
    overlays.default = final: prev: {
      zmux = mkZmux (prev.extend zig.overlays.default);
    };

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
