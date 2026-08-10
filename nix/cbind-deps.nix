# Nim dep set consumed by cbind.nix. This is a SCAFFOLD:
#   - The `rev` pins are correct (they mirror the ones in nim-libp2p/cbind
#     and mix-rln-spam-protection-plugin.nimble).
#   - The `sha256` values are PLACEHOLDERS. Regenerate them with
#     `nix-prefetch-git --url <url> --rev <rev> --fetch-submodules` and
#     replace the `PLACEHOLDER-...` strings before this file will evaluate.
#   - Deps transitively required by mix-rln-spam-protection-plugin
#     (nim-libp2p 2.1.4, nim-libp2p-mix at c387ca67…, secp256k1, chronicles,
#     chronos, results, stew, nimcrypto, json_serialization, unittest2, …)
#     also need entries here — the current list only covers what nim-libp2p's
#     cbind pins directly.
{ pkgs }:

{
  cbor_serialization = pkgs.fetchgit {
    url = "https://github.com/vacp2p/nim-cbor-serialization";
    rev = "1664160e04d153573373afddc552b9cbf6fbe4dc";
    sha256 = "0c1rj4fk0fcqvsf0yqhxvm8h10aww75gi4yfsjhlczh88ypywii2";
    fetchSubmodules = true;
  };

  taskpools = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-taskpools";
    rev = "9e8ccc754631ac55ac2fd495e167e74e86293edb";
    sha256 = "1y78l33vdjxmb9dkr455pbphxa73rgdsh8m9gpkf4d9b1wm1yivy";
    fetchSubmodules = true;
  };

  ffi = pkgs.fetchgit {
    url = "https://github.com/logos-messaging/nim-ffi";
    rev = "b95e2b04a63fbd417938bf3ec0ac14be7935e21b";
    sha256 = "16iynxgls3w9gsy79m1z29s6r8d09xpzsm7rl29q72gs0n9i26m0";
    fetchSubmodules = true;
  };

  # ---------------------------------------------------------------------------
  # TODO: pins below still need real sha256s (placeholders won't evaluate).
  # ---------------------------------------------------------------------------

  libp2p = pkgs.fetchgit {
    url = "https://github.com/vacp2p/nim-libp2p";
    rev = "v2.1.4";
    sha256 = "PLACEHOLDER-nix-prefetch-git-required";
    fetchSubmodules = true;
  };

  libp2p_mix = pkgs.fetchgit {
    url = "https://github.com/logos-co/nim-libp2p-mix";
    rev = "c387ca67cf477dc53ec6228027c45d8eda067917";
    sha256 = "PLACEHOLDER-nix-prefetch-git-required";
    fetchSubmodules = true;
  };

  mix_rln_spam_protection = pkgs.fetchgit {
    url = "https://github.com/logos-co/mix-rln-spam-protection-plugin";
    rev = "master";
    sha256 = "PLACEHOLDER-nix-prefetch-git-required";
    fetchSubmodules = true;
  };
}
