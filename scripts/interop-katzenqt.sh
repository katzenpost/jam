#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# posse and katzenqt in one group, through a running kpclientd.
#
#   scripts/interop-katzenqt.sh host|guest [DAEMON] [KATZENQT_DIR]
#
# host:  posse founds the group and inducts katzenqt, which mints the voucher.
# guest: katzenqt founds the group and inducts posse, which mints the voucher.
# katzenqt must be checked out at a branch that speaks posse's group chat (acks-idx64), with its
# virtualenv in .venv. Its state goes to a fresh directory, never the user's.
set -euo pipefail

role=${1:?host or guest}
daemon=${2:-@katzenpost}
katzenqt=${3:-../katzenqt}
here=$(cd "$(dirname "$0")/.." && pwd)
kq="$katzenqt/.venv/bin/katzenqt-headless"
case $daemon in
  @*|/*) conn=(--address "$daemon" --network unix) ;;
  *) conn=(--address "$daemon" --network tcp) ;;
esac

export XDG_DATA_HOME
XDG_DATA_HOME=$(mktemp -d)
export KQT_STATE=interop
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
mkfifo "$work/to-posse"
rm -rf "$here/.lake/posse-interop"
(cd "$here" && .lake/build/bin/posse-interop "$role" "$daemon" 40 < "$work/to-posse" > "$work/posse.out" 2> "$work/posse.log") &
posse=$!
exec 3> "$work/to-posse"

wait_for() { until grep -q "$1" "$work/posse.out"; do kill -0 $posse 2>/dev/null || { cat "$work/posse.log"; exit 1; }; sleep 2; done; }
step() { echo "== $*"; }

"$kq" create-conv g katzenqt "${conn[@]}" 2> "$work/create.log"
if [ "$role" = host ]; then
  wait_for READY
  step "katzenqt mints a voucher"
  code=$("$kq" voucher-mint g katzenqt "${conn[@]}" 2>&1 | sed -n 's/.*VOUCHER=//p' | tail -1)
  test -n "$code"
  echo "$code" >&3
  step "katzenqt waits for posse to let it in"
  "$kq" voucher-await g "${conn[@]}"
else
  wait_for VOUCHER=
  code=$(sed -n 's/^VOUCHER=//p' "$work/posse.out")
  step "katzenqt inducts posse"
  "$kq" voucher-induct g posse "$code" "${conn[@]}"
fi
step "katzenqt sends"
"$kq" send g "from katzenqt" "${conn[@]}"
step "katzenqt reads posse"
"$kq" read g 1800 "from posse" "${conn[@]}"
step "katzenqt acknowledges"
"$kq" send g "katzenqt read you" "${conn[@]}"
wait $posse && result=0 || result=$?
cat "$work/posse.out"
grep -E "^(ok|FAIL)" "$work/posse.log" || true
exit $result
