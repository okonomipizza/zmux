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
    packages = forAllSystems (pkgs: {
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.zmux;

      zmux = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "zmux";
        version = "0.1.0";
        src = self;

        nativeBuildInputs = [pkgs.zigpkgs.${zigVersion}];

        dontConfigure = true;

        buildPhase = ''
          runHook preBuild
          zig build --prefix $out -Doptimize=ReleaseSafe
          runHook postBuild
        '';

        # `zig build` already installs into --prefix.
        dontInstall = true;

        meta = {
          description = "A simple terminal multiplexer with persistent floating panes";
          homepage = "https://github.com/okonomipizza/zmux";
          license = lib.licenses.mit;
          mainProgram = "zmux";
          platforms = lib.platforms.unix;
        };
      });
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "zmux";

        packages = [
          pkgs.zigpkgs.${zigVersion}
          pkgs.zls
        ];

        shellHook = ''
          echo "zmux dev shell"
          echo "  zig $(zig version)"
        '';
      };
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
