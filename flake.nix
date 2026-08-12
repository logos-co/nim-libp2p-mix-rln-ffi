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

      # mix-rln-spam-protection-plugin's Nim binding declares
      # `proc ffi_rln_new(): CResultRLNPtrVecU8` — the zero-arg form. Zerokit
      # exposes that variant only under `--features=stateless`; the default
      # build produces `ffi_rln_new(tree_depth, config_path)`. Same symbol,
      # different arity → calling the default build with 0 args segfaults
      # inside Rust. Consume the `rln-stateless` output rather than `rln`.
      # (Our zerokit input must expose one — see the local zerokit-v2 fork's
      # flake.nix, which adds `rln-stateless = buildRln.override { features =
      # "stateless"; }` next to `rln`.)
      librlnOf = system:
        "${zerokit.packages.${system}.rln-stateless}/lib/librln.a";
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          # `cbind`: the FFI artifact consumed by logos-libp2p-mix-rln's flake.
          cbind = import ./nix/cbind.nix {
            inherit pkgs;
            src = ./.;
            librln = librlnOf system;
          };

          # `test-mix-routing`: builds AND runs tests/test_mix_routing.nim as
          # part of the derivation. A passing build = a passing test.
          test-mix-routing = import ./nix/test-mix-routing.nix {
            inherit pkgs;
            src = ./.;
            librln = librlnOf system;
          };

          # `test-mix-routing-rln`: same, but every mix node has an RLN
          # SpamProtection plugin wired in and per-hop proofs are generated
          # and verified along the whole Sphinx path. Uses an in-process
          # publish bus to cross-sync memberships between plugins.
          test-mix-routing-rln = import ./nix/test-mix-routing-rln.nix {
            inherit pkgs;
            src = ./.;
            librln = librlnOf system;
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
              zerokit.packages.${system}.rln-stateless
            ];
            shellHook = ''
              export LIBRLN_PATH=${librlnOf system}
            '';
          };
        }
      );
    };
}
