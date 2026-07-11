{
  description = "Tiler — scrollable tiling window manager for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        swiftFormat = pkgs.swift-format;
      in
      {
        devShells.default = pkgs.mkShellNoCC {
          packages = [ swiftFormat ];
        };

        # `nix fmt` — format Swift sources in place.
        formatter = pkgs.writeShellApplication {
          name = "fmt";
          runtimeInputs = [ swiftFormat ];
          text = ''
            swift-format format --in-place --recursive --parallel Sources Tests
          '';
        };
      }
    );
}