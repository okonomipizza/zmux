{
  description = "terminal multiplexer written by zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    zls = {
      url = "github:zigtools/zls/0.15.1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig";
      };
    };
    ghostty = {
      url = "github:ghostty-org/ghostty/v1.3.1";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    zls,
    ghostty,
    ...
  }:
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          devShell.${system} = pkgs.callPackage ./nix/devShell.nix {
            zig = zig.packages.${system}."0.15.2";
            zls = zls.packages.${system}.zls;
            ghosttySrc = ghostty;
          };

          packages.${system}.default = pkgs.callPackage ./nix/packages.nix {
            zig = zig.packages.${system}."0.15.2";
            ghosttySrc = ghostty;
          };

          formatter.${system} = pkgs.alejandra;
        }
      ) (builtins.attrNames zig.packages)
    );
}
