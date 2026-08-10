{
  description = "C FFI facade for nim-libp2p + nim-libp2p-mix + mix-rln-spam-protection-plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
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
          # Requires `librln` to be passed. `nix build .#cbind` will fail with
          # a helpful message until librln packaging is wired.
          cbind = import ./nix/cbind.nix {
            inherit pkgs;
            src = ./.;
            # TODO: derive librln from a vacp2p/zerokit input once packaged
            # for nix. For now the default is null and the derivation throws.
            librln = null;
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
            ];
          };
        }
      );
    };
}
