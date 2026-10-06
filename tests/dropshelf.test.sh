#!/bin/bash
# Drives bin/dropshelf against planted files in a throwaway HOME.
# Run: bash tests/dropshelf.test.sh
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$here/bin/dropshelf"
work="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || { chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"; }; [ -n "${shm:-}" ] && rm -rf "$shm"' EXIT
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

# ---- zip ----
zsrc="$HOME/zsrc"
zdst="$HOME/zdst"
mkdir -p "$zsrc/album/sub" "$zdst"
echo one > "$zsrc/one.txt"
echo two > "$zsrc/album/sub/two.txt"
ln -s ../one.txt "$zsrc/album/link"
deliver zip "$zdst" "$zsrc/one.txt" > "$work/z1"
check "zip of one item is named after it" '[ -f "$zdst/one.txt.zip" ] && [ "$(field done ok < "$work/z1")" = 1 ]'
deliver zip "$zdst" "$zsrc/one.txt" "$zsrc/album" > "$work/z2"
zipname="$(field item dest < "$work/z2" | head -1)"
check "zip of several is named after this host and the time" '[[ "$zipname" =~ ^$(hostname -s | tr -cd "A-Za-z0-9_-")-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.zip$ ]] && [ -f "$zdst/$zipname" ]'
names="$(/usr/bin/python3 -c 'import zipfile,sys; print(" ".join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))' "$zdst/$zipname")"
check "zip holds files and folders, skips links" '[ "$names" = "album/ album/sub/ album/sub/two.txt one.txt" ]'
check "zip says it skipped the link" 'grep -q "skipped 1" "$work/z2"'
check "zip content intact" '[ "$(cd "$work" && unzip -p "$zdst/$zipname" album/sub/two.txt)" = two ]'
deliver zip "$zdst" "$zsrc/one.txt" > /dev/null
check "a second zip of the same item gets (2)" '[ -f "$zdst/one.txt (2).zip" ] && [ -e "$zsrc/one.txt" ]'
deliver zip "$zdst" "$zsrc/gone" > "$work/z3"
check "zip with nothing readable leaves no archive" '[ ! -e "$zdst/gone.zip" ] && [ "$(field done ok < "$work/z3")" = 0 ]'

# ---- hosts ----
mkdir -p "$HOME/.ssh/conf.d"
cat > "$HOME/.ssh/config" <<'CFG'
Include conf.d/*.conf
Host *
  ServerAliveInterval 30
Host alpha beta
  User me
Host github.com
  User git
Host -evil
Match host x
  User git
CFG
printf 'Host gamma\n  HostName 10.0.0.3\nHost forge\n  User git\n' > "$HOME/.ssh/conf.d/extra.conf"
check "hosts: aliases, includes, no patterns or git hosts" '[ "$(run hosts)" = "[\"gamma\", \"alpha\", \"beta\"]" ]'

# ---- send over ssh (a stand-in ssh runs the remote side here) ----
stub="$work/stub"
mkdir -p "$stub"
cat > "$stub/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGV"
while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
host="$1"; shift
[ "$host" = deadhost ] && { echo "ssh: Could not resolve hostname deadhost: Name or service not known" >&2; exit 255; }
if [ "$host" = winbox ]; then
  cat >/dev/null
  printf '\033[31;1msh : The term \x27sh\x27 is not recognized as a name of a cmdlet.\033[0m\n\033[31;1mCheck the spelling of the name.\033[0m\n' >&2
  exit 1
fi
cd "$HOME" && exec bash -c "$*"
STUB
chmod +x "$stub/ssh"
export STUB_ARGV="$work/argv"
send() { # mode host dir paths...
  local mode="$1" host="$2" dir="$3"; shift 3
  /usr/bin/python3 -c 'import json,sys; print(json.dumps({"mode": sys.argv[1], "host": sys.argv[2], "dir": sys.argv[3], "items": sys.argv[4:]}))' \
    "$mode" "$host" "$dir" "$@" | PATH="$stub:$PATH" /usr/bin/python3 "$helper" send
}
ssrc="$HOME/ssrc"
mkdir -p "$ssrc/secret-folder/inner" "$HOME/inbox"
echo payload > "$ssrc/secret-name.txt"
echo deep > "$ssrc/secret-folder/inner/deep.txt"
ln -s inner/deep.txt "$ssrc/secret-folder/shortcut"
echo old > "$HOME/inbox/secret-name.txt"
send copy box "~/inbox" "$ssrc/secret-name.txt" "$ssrc/secret-folder" > "$work/s1"
check "send copy reports 2 ok" '[ "$(field done ok < "$work/s1")" = 2 ]'
check "send never overwrites" '[ "$(cat "$HOME/inbox/secret-name.txt")" = old ] && [ "$(cat "$HOME/inbox/secret-name (2).txt")" = payload ]'
check "send keeps folders and links" '[ "$(cat "$HOME/inbox/secret-folder/inner/deep.txt")" = deep ] && [ -L "$HOME/inbox/secret-folder/shortcut" ]'
check "send leaves no temp folder" '[ -z "$(ls -A "$HOME/inbox" | grep "^\.dropzone")" ]'
check "send copy keeps the originals" '[ -e "$ssrc/secret-name.txt" ] && [ -d "$ssrc/secret-folder" ]'
check "no file name or folder in ssh argv" '! grep -qE "secret|inbox" "$STUB_ARGV"'
send move box "~/inbox" "$ssrc/secret-name.txt" "$ssrc/secret-folder" > "$work/s2"
check "send move removes originals after placing" '[ "$(field done ok < "$work/s2")" = 2 ] && [ ! -e "$ssrc/secret-name.txt" ] && [ ! -e "$ssrc/secret-folder" ] && [ -e "$HOME/inbox/secret-name (3).txt" ] && [ -d "$HOME/inbox/secret-folder (2)" ]'
echo again > "$ssrc/again.txt"
send move box "~/nowhere" "$ssrc/again.txt" > "$work/s3"
check "missing remote folder: reported, original kept" '[ "$(field item error < "$work/s3")" = "no such folder on the host" ] && [ -e "$ssrc/again.txt" ]'
send move deadhost "~/inbox" "$ssrc/again.txt" > "$work/s4"
check "unreachable host: ssh error reported, original kept" 'field item error < "$work/s4" | grep -q "Could not resolve" && [ -e "$ssrc/again.txt" ]'
mkdir -p "$ssrc/withpipe"
echo keep > "$ssrc/withpipe/keep.txt"
mkfifo "$ssrc/withpipe/pipe"
send move box "~/inbox" "$ssrc/withpipe" > "$work/s5"
check "move keeps an original with skipped special files" '[ -e "$ssrc/withpipe/keep.txt" ] && grep -q "original was kept" "$work/s5" && [ -e "$HOME/inbox/withpipe/keep.txt" ]'
send copy "-oProxyCommand=x" "~/inbox" "$ssrc/again.txt" > /dev/null 2>&1
check "host that looks like an option refused" '[ $? -eq 3 ]'
mkdir -p "$HOME/odd dir \$x \"q\""
send copy box "~/odd dir \$x \"q\"" "$ssrc/again.txt" > "$work/s6"
check "odd remote folder name handled literally" '[ "$(field done ok < "$work/s6")" = 1 ] && [ -e "$HOME/odd dir \$x \"q\"/again.txt" ]'

# ---- zip sent over ssh ----
mkdir -p "$HOME/zipbox" "$ssrc/zipme/sub"
echo a > "$ssrc/zipme/sub/a.txt"
echo b > "$ssrc/b.txt"
send zip box "~/zipbox" "$ssrc/zipme" "$ssrc/b.txt" > "$work/sz1"
sentzip="$(field item dest < "$work/sz1" | head -1)"
check "zip to host: one archive placed, both items ok" '[ "$(field done ok < "$work/sz1")" = 2 ] && [ -f "$HOME/zipbox/$sentzip" ] && [[ "$sentzip" == *-*.zip ]]'
check "zip to host: archive content" '[ "$(cd "$work" && unzip -p "$HOME/zipbox/$sentzip" zipme/sub/a.txt)" = a ]'
check "zip to host: originals kept" '[ -e "$ssrc/b.txt" ] && [ -d "$ssrc/zipme" ]'
check "zip to host: no temp folder left" '[ -z "$(ls -A "$HOME/.cache/dropshelf" 2>/dev/null)" ]'
send zip box "~/zipbox" "$ssrc/b.txt" > /dev/null
send zip box "~/zipbox" "$ssrc/b.txt" > /dev/null
check "zip to host: second archive of the same name gets (2)" '[ -f "$HOME/zipbox/b.txt (2).zip" ]'
send zip deadhost "~/zipbox" "$ssrc/b.txt" > "$work/sz2"
check "zip to unreachable host: failed, temp removed" 'field item error < "$work/sz2" | grep -q "Could not resolve" && [ -z "$(ls -A "$HOME/.cache/dropshelf" 2>/dev/null)" ]'

# ---- a Windows host answers in colour ----
send copy winbox "~/inbox" "$ssrc/b.txt" > "$work/sw"
err="$(field item error < "$work/sw")"
check "windows host: plain explanation, no escape codes" '[ "$err" = "the host has no Unix shell (Windows?); Drop Zone needs sh, tar and mv there" ]'
check "no control characters anywhere in the output" '! LC_ALL=C grep -q "$(printf "\033")" "$work/sw"'

# ---- review fixes 0.2.1 ----
# Copies follow the umask, like cp without -p.
mkdir -p "$HOME/um/src/open" "$HOME/um/dst"
echo w > "$HOME/um/src/open.txt"; chmod 666 "$HOME/um/src/open.txt"
echo i > "$HOME/um/src/open/in.txt"; chmod 777 "$HOME/um/src/open"
(umask 022; deliver copy "$HOME/um/dst" "$HOME/um/src/open.txt" "$HOME/um/src/open" > /dev/null)
check "copied file loses group/other write" '[ "$(stat -c %a "$HOME/um/dst/open.txt")" = 644 ]'
check "copied folder loses group/other write" '[ "$(stat -c %a "$HOME/um/dst/open")" = 755 ]'
# The host folder must not be writable by group or others.
mkdir -p "$HOME/sharedbox" "$HOME/groupbox"; chmod 777 "$HOME/sharedbox"; chmod 775 "$HOME/groupbox"
echo s > "$ssrc/s.txt"
send copy box "~/sharedbox" "$ssrc/s.txt" > "$work/r1"
check "world-writable host folder refused" 'field item error < "$work/r1" | grep -q "writable by others" && [ -z "$(ls -A "$HOME/sharedbox")" ]'
send move box "~/groupbox" "$ssrc/s.txt" > "$work/r2"
check "group-writable host folder refused, original kept" 'field item error < "$work/r2" | grep -q "writable by others" && [ -e "$ssrc/s.txt" ]'
# Names come back as they are, backslashes included.
printf x > "$ssrc/back\\cslash.txt"
send copy box "~/inbox" "$ssrc/back\\cslash.txt" > "$work/r3"
check "name with a backslash reported intact" '[ "$(field item dest < "$work/r3")" = "back\\cslash.txt" ] && [ -e "$HOME/inbox/back\\cslash.txt" ]'
# A staged link is sent as a link; its target's content never travels.
echo "TOP-SECRET" > "$HOME/private.txt"
ln -s "$HOME/private.txt" "$ssrc/innocent.txt"
send copy box "~/inbox" "$ssrc/innocent.txt" > /dev/null
check "staged link arrives as a link" '[ -L "$HOME/inbox/innocent.txt" ]'
# Temp zips left by a killed run are cleared; a fresh one is left alone.
mkdir -p "$HOME/.cache/dropshelf/zip-stale" "$HOME/.cache/dropshelf/zip-fresh"
echo old > "$HOME/.cache/dropshelf/zip-stale/Archive.zip"
touch -d "3 hours ago" "$HOME/.cache/dropshelf/zip-stale"
send zip box "~/zipbox" "$ssrc/b.txt" > /dev/null
check "stale temp zip removed, fresh one kept" '[ ! -e "$HOME/.cache/dropshelf/zip-stale" ] && [ -d "$HOME/.cache/dropshelf/zip-fresh" ]'
rmdir "$HOME/.cache/dropshelf/zip-fresh"
check "the swap race test passes" '/usr/bin/python3 "$here/tests/send_race.test.py" > /dev/null'

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
