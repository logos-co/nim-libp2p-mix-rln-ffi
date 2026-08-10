# Convenience wrappers over the nimble tasks. The hermetic path is
# `nix build .#cbind` — the flake produces the same artifacts.

LIBRLN_PATH ?= $(CURDIR)/librln.a

.PHONY: setup buildffi genbindings clean check-librln

check-librln:
	@test -f "$(LIBRLN_PATH)" || (echo "LIBRLN_PATH=$(LIBRLN_PATH) not found; build librln.a from vacp2p/zerokit first" >&2; exit 1)

setup:
	nimble -l setup -y

buildffi: check-librln
	LIBRLN_PATH=$(LIBRLN_PATH) nimble buildffi

genbindings:
	nimble genbindings_c

clean:
	rm -rf build nimcache nimcache_c c_bindings
