# SPDX-License-Identifier: AGPL-3.0-only

katzenpost_ref?=2405aa1119404b1e27cce0566729141102d769f0
katzenpost_dir?=.katzenpost

.PHONY: build release test test-integration

build:
	lake exe cache get && lake build jam

# The binary and its SHA256SUMS in dist/, the same bytes on every machine.
release:
	sh scripts/release-build.sh dist

# In one process, against a simulated Pigeonhole.
test:
	lake exe cache get && lake build jam-test && lake exe jam-test

# Two members over the docker mixnet's client daemon, as test-integration.sh starts it.
test-integration:
	lake exe cache get && lake build jam-integration && \
	lake exe jam-integration 127.0.0.1:33399 30
