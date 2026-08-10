{
  description = "C FFI facade for nim-libp2p + nim-libp2p-mix + mix-rln-spam-protection-plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    zerokit.url = "github:vacp2p/zerokit";
  };

  outputs = { self, nixpkgs, zerokit }:
    let
      systems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          # `cbind`: the FFI artifact consumed by logos-libp2p-mix-rln's flake.
          # librln.a is sourced from vacp2p/zerokit's rln package.
          cbind = import ./nix/cbind.nix {
            inherit pkgs;
            src = ./.;
            librln = "${zerokit.packages.${system}.rln}/lib/librln.a";
          };
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              pkgs.nim-2_2
              pkgs.nimble
              pkgs.git
              zerokit.packages.${system}.rln
            ];
            shellHook = ''
              export LIBRLN_PATH=${zerokit.packages.${system}.rln}/lib/librln.a
            '';
          };
        }
      );
    };
}
