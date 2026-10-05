#!/bin/bash
# Drives bin/dropshelf against planted files in a throwaway HOME.
# Run: bash tests/dropshelf.test.sh
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$here/bin/dropshelf"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"; [ -n "${shm:-}" ] && rm -rf "$shm"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
chmod 700 "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

run() { /usr/bin/python3 "$helper" "$@"; }
deliver() { # mode target paths... → JSON lines on stdout
  local mode="$1" target="$2"; shift 2
  /usr/bin/python3 -c 'import json,sys; print(json.dumps({"mode": sys.argv[1], "target": sys.argv[2], "items": sys.argv[3:]}))' \
    "$mode" "$target" "$@" | run deliver
}
field() { /usr/bin/python3 -c 'import json,sys
for line in sys.stdin:
    o = json.loads(line)
    if o.get("type") == sys.argv[1]: print(o.get(sys.argv[2], ""))' "$1" "$2"; }

# ---- state ----
state="$HOME/.local/state/dropshelf/state.json"
check "state read with no file prints {}" '[ "$(run state read "$state")" = "{}" ]'
echo '{"items":[]}' | run state write "$state"
check "state round trip" '[ "$(run state read "$state")" = "{\"items\":[]}" ]'
check "state dir is 0700" '[ "$(stat -c %a "$HOME/.local/state/dropshelf")" = 700 ]'
check "state file is 0600" '[ "$(stat -c %a "$state")" = 600 ]'
mkdir -p "$work/elsewhere"
rm -rf "$HOME/.local/state/dropshelf"
ln -s "$work/elsewhere" "$HOME/.local/state/dropshelf"
echo '{}' | run state write "$state" 2>/dev/null
check "symlinked state dir refused" '[ $? -eq 3 ] && [ ! -e "$work/elsewhere/state.json" ]'
rm "$HOME/.local/state/dropshelf"
mkdir -m 700 "$HOME/.local/state/dropshelf"
ln -s "$work/elsewhere/planted" "$state"
echo '{}' | run state write "$state" 2>/dev/null
check "symlinked state file refused" '[ $? -eq 3 ] && [ ! -e "$work/elsewhere/planted" ]'
rm "$state"
head -c 600000 /dev/zero | run state write "$state" 2>/dev/null
check "oversized state refused" '[ $? -eq 3 ] && [ ! -e "$state" ]'
check "payload in argv refused" 'run deliver /tmp >/dev/null 2>&1; [ $? -eq 1 ]'

# ---- inspect ----
src="$HOME/src"
mkdir -p "$src/folder/inner"
echo hello > "$src/a.txt"
echo report > "$src/my.report.pdf"
echo tarball > "$src/backup.tar.gz"
echo nested > "$src/folder/inner/deep.txt"
ln -s ../a.txt "$src/folder/link-to-a"
mkfifo "$src/folder/pipe"
ln -s a.txt "$src/toplink"
out="$(/usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$src/a.txt" "$src/folder" "$src/toplink" "$src/gone" "relative" | run inspect)"
check "inspect kinds" '[ "$(echo "$out" | /usr/bin/python3 -c "import json,sys; print(\" \".join(o[\"kind\"] for o in json.load(sys.stdin)))")" = "file folder link missing invalid" ]'
check "inspect size" '[ "$(echo "$out" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"size\"])")" = 6 ]'

# ---- copy ----
dst="$HOME/dst"
mkdir -p "$dst"
deliver copy "$dst" "$src/a.txt" "$src/my.report.pdf" "$src/backup.tar.gz" > "$work/out1"
check "copy reports 3 ok" '[ "$(field done ok < "$work/out1")" = 3 ]'
check "copied content" '[ "$(cat "$dst/a.txt")" = hello ] && [ -e "$src/a.txt" ]'
deliver copy "$dst" "$src/a.txt" "$src/my.report.pdf" "$src/backup.tar.gz" > /dev/null
check "taken names get (2)" '[ -e "$dst/a (2).txt" ] && [ -e "$dst/my.report (2).pdf" ] && [ -e "$dst/backup (2).tar.gz" ]'
check "original copy untouched" '[ "$(cat "$dst/a.txt")" = hello ]'
ln -s "$work/trap-target" "$dst/trap.txt"
echo bait > "$src/trap.txt"
deliver copy "$dst" "$src/trap.txt" > /dev/null
check "dangling symlink at the name is not followed" '[ ! -e "$work/trap-target" ] && [ "$(cat "$dst/trap (2).txt")" = bait ]'
deliver copy "$dst" "$src/folder" > "$work/out2"
check "folder copied" '[ "$(cat "$dst/folder/inner/deep.txt")" = nested ]'
check "link inside folder copied as a link" '[ -L "$dst/folder/link-to-a" ] && [ "$(readlink "$dst/folder/link-to-a")" = ../a.txt ]'
check "fifo skipped and said so" '[ ! -e "$dst/folder/pipe" ] && grep -q "skipped 1" "$work/out2"'
deliver copy "$dst" "$src/toplink" > /dev/null
check "top-level link copied as a link" '[ -L "$dst/toplink" ]'
deliver copy "$dst" "$src/nothing-here" > "$work/out3"
check "missing source reported" '[ "$(field item error < "$work/out3")" = "no longer there" ]'
deliver copy "$src/folder/inner" "$src/folder" > "$work/out4"
check "folder into itself refused" '[ "$(field item error < "$work/out4")" = "a folder cannot go inside itself" ]'
check "copy into its own folder makes (2)" 'deliver copy "$src" "$src/a.txt" >/dev/null; [ -e "$src/a (2).txt" ]'
rm -f "$src/a (2).txt"
check "target that is a file refused" 'deliver copy "$src/a.txt" "$src/a.txt" >/dev/null 2>&1; [ $? -eq 3 ]'
check "relative target refused" 'deliver copy "relative" "$src/a.txt" >/dev/null 2>&1; [ $? -eq 3 ]'

# ---- move ----
mv_src="$HOME/mvsrc"
mv_dst="$HOME/mvdst"
mkdir -p "$mv_src/dir" "$mv_dst"
echo one > "$mv_src/one.txt"
echo two > "$mv_src/dir/two.txt"
echo clash > "$mv_dst/one.txt"
deliver move "$mv_dst" "$mv_src/one.txt" "$mv_src/dir" > "$work/out5"
check "move reports 2 ok" '[ "$(field done ok < "$work/out5")" = 2 ]'
check "moved, no overwrite" '[ ! -e "$mv_src/one.txt" ] && [ "$(cat "$mv_dst/one (2).txt")" = one ] && [ "$(cat "$mv_dst/one.txt")" = clash ]'
check "folder moved" '[ ! -e "$mv_src/dir" ] && [ "$(cat "$mv_dst/dir/two.txt")" = two ]'
deliver move "$mv_dst" "$mv_dst/one.txt" > "$work/out6"
check "move into its own folder is a no-op" '[ "$(field item note < "$work/out6")" = "already there" ] && [ "$(cat "$mv_dst/one.txt")" = clash ] && [ ! -e "$mv_dst/one (3).txt" ]'

# Across file systems: /dev/shm is its own tmpfs.
if [ -d /dev/shm ] && [ -w /dev/shm ] && [ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$HOME")" ]; then
  shm="$(mktemp -d /dev/shm/dropshelf-test.XXXXXX)"
  mkdir -p "$shm/tree/sub"
  echo far > "$shm/far.txt"
  echo deeper > "$shm/tree/sub/x.txt"
  deliver move "$mv_dst" "$shm/far.txt" "$shm/tree" > "$work/out7"
  check "cross-fs move copies then removes" '[ "$(field done ok < "$work/out7")" = 2 ] && [ ! -e "$shm/far.txt" ] && [ "$(cat "$mv_dst/far.txt")" = far ] && [ ! -e "$shm/tree" ] && [ "$(cat "$mv_dst/tree/sub/x.txt")" = deeper ]'
  mkdir -p "$shm/special"
  mkfifo "$shm/special/fifo"
  echo keep > "$shm/special/keep.txt"
  deliver move "$mv_dst" "$shm/special" > "$work/out8"
  check "cross-fs move keeps a source it could not copy whole" '[ -e "$shm/special/keep.txt" ] && grep -q "original was kept" "$work/out8"'
else
  echo "skip: no separate tmpfs at /dev/shm for the cross-fs move test"
fi

# ---- cancel ----
big="$HOME/big.bin"
head -c 200000000 /dev/urandom > "$big" 2>/dev/null
cancel_dst="$HOME/cancel"
mkdir -p "$cancel_dst"
/usr/bin/python3 -c 'import json,sys; print(json.dumps({"mode": "copy", "target": sys.argv[1], "items": [sys.argv[2]]}))' "$cancel_dst" "$big" \
  | /usr/bin/python3 "$helper" deliver > "$work/out9" &
pid=$!
for _ in $(seq 1 50); do grep -q '"begin"' "$work/out9" 2>/dev/null && break; sleep 0.02; done
kill -TERM "$pid" 2>/dev/null
wait "$pid"
code=$?
if grep -q '"done"' "$work/out9"; then
  echo "skip: the copy finished before the cancel landed"
else
  check "cancel exits 130" '[ "$code" -eq 130 ]'
  check "cancel leaves no partial file" '[ -z "$(ls -A "$cancel_dst")" ]'
  check "cancel keeps the source" '[ -s "$big" ]'
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
