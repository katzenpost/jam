#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

katzenpost_ref=${katzenpost_ref:-$(sed -n 's/^katzenpost_ref?=\(.*\)$/\1/p' Makefile)}
katzenpost_dir=${katzenpost_dir:-.katzenpost}

if [ ! -d "$katzenpost_dir/.git" ]; then
	git clone --quiet https://github.com/katzenpost/katzenpost "$katzenpost_dir"
fi
git -C "$katzenpost_dir" fetch --quiet origin "$katzenpost_ref" || true
git -C "$katzenpost_dir" checkout --quiet "$katzenpost_ref"

trap 'make -C "$katzenpost_dir/docker" stop || true' EXIT INT TERM
make -C "$katzenpost_dir/docker" start wait
make test-integration
