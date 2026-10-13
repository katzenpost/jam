#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# jam and katzenqt in one group, through a running kpclientd.
#
#   scripts/interop-katzenqt.sh host|guest [DAEMON] [KATZENQT_DIR]
#
# host:  jam founds the group and inducts katzenqt, which mints the voucher.
# guest: katzenqt founds the group and inducts jam, which mints the voucher.
# katzenqt must be checked out at a branch that speaks jam's group chat (acks-idx64), with its
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
mkfifo "$work/to-jam"
rm -rf "$here/.lake/jam-interop"
(cd "$here" && .lake/build/bin/jam-interop "$role" "$daemon" 40 < "$work/to-jam" > "$work/jam.out" 2> "$work/jam.log") &
jam=$!
exec 3> "$work/to-jam"

wait_for() { until grep -q "$1" "$work/jam.out"; do kill -0 $jam 2>/dev/null || { cat "$work/jam.log"; exit 1; }; sleep 2; done; }
step() { echo "== $*"; }

"$kq" create-conv g katzenqt "${conn[@]}" 2> "$work/create.log"
if [ "$role" = host ]; then
  wait_for READY
  step "katzenqt mints a voucher"
  code=$("$kq" voucher-mint g katzenqt "${conn[@]}" 2>&1 | sed -n 's/.*VOUCHER=//p' | tail -1)
  test -n "$code"
  echo "$code" >&3
  step "katzenqt waits for jam to let it in"
  "$kq" voucher-await g "${conn[@]}"
else
  wait_for VOUCHER=
  code=$(sed -n 's/^VOUCHER=//p' "$work/jam.out")
  step "katzenqt inducts jam"
  "$kq" voucher-induct g jam "$code" "${conn[@]}"
fi
step "katzenqt sends"
"$kq" send g "from katzenqt" "${conn[@]}"
step "katzenqt reads jam"
"$kq" read g 1800 "from jam" "${conn[@]}"
step "katzenqt acknowledges"
"$kq" send g "katzenqt read you" "${conn[@]}"
wait $jam && result=0 || result=$?
cat "$work/jam.out"
grep -E "^(ok|FAIL)" "$work/jam.log" || true
exit $result
