#!/bin/bash
# Runs dit-offloader against fake cards in a temporary folder, with stand-ins for the
# macOS disk tools, so it works on macOS and Linux and touches no real drive.
# Usage: tests/run-tests.sh
# shellcheck disable=SC2016,SC2034
TOOL="$(cd "$(dirname "$0")/.." && pwd)/bin/dit-offloader"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ejected"
cat > "$T/bin/diskutil" <<'SHIM'
#!/bin/bash
case "$1" in
  rename) mv "$2" "$(dirname "$2")/$3" ;;
  eject)  mv "$2" "$SHIM_EJECTED/$(basename "$2")-$$" ;;
esac
SHIM
cat > "$T/bin/hdiutil" <<'SHIM'
#!/bin/bash
case "$1" in
  attach) n="${2#/tmp/dit-offloader-fake-}"; mkdir -p "$DIT_OFFLOADER_VOLUMES/${n%-*}" ;;
  detach) mv "$2" "$SHIM_EJECTED/$(basename "$2")-$$" ;;
esac
SHIM
mkdir -p "$T/dfbin"
cat > "$T/dfbin/df" <<'SHIM'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fakedisk 1000000 0 $FAKE_FREE_KB 0% /fake drive"
SHIM
chmod +x "$T/dfbin/df"
chmod +x "$T/bin/"*
# The helper that clears copies from memory before they are checked (Homebrew builds it).
cc -O2 -o "$T/bin/dit-offloader-evict" "$(dirname "$TOOL")/../src/dit-offloader-evict.c" || exit 1
# Runs a command in a simulated terminal, typing answers when prompts appear:
#   python3 drive.py "<prompt text>=<answer>"... -- command args
cat > "$T/drive.py" <<'PYTHON'
import os, pty, select, sys, time
cut = sys.argv.index("--")
pairs = [a.split("=", 1) for a in sys.argv[1:cut]]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[cut + 1], sys.argv[cut + 1:])
buf, start = b"", time.time()
while time.time() - start < 90:
    ready, _, _ = select.select([fd], [], [], 0.3)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
    if pairs and pairs[0][0].encode() in buf:
        time.sleep(0.2)
        os.write(fd, pairs.pop(0)[1].encode() + b"\r")
os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
PYTHON
export PATH="$T/bin:$PATH" SHIM_EJECTED="$T/ejected" DIT_OFFLOADER_ALLOW_NON_MAC=1
export DIT_OFFLOADER_VOLUMES="$T/vol" DIT_OFFLOADER_STATE="$T/state" DIT_OFFLOADER_CONFIG="$T/config"
V="$T/vol"; TODAY="$(date '+%y%m%d')"; ISO="$(date '+%Y-%m-%d')"
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
settle() { local i=0; while pgrep -f "dit-offloader _run" >/dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done; sleep 1; }
reset() { rm -rf "$V" "$T/state" "$T/ejected"; mkdir -p "$V/one" "$V/two" "$T/ejected"; }
sony_card() {  # name letter
  mkdir -p "$V/$1/XDROOT/Clip" "$V/$1/XDROOT/Sub"
  head -c 200000 /dev/urandom > "$V/$1/XDROOT/Clip/${2}001L001_x.MXF"
  head -c 100000 /dev/urandom > "$V/$1/XDROOT/Clip/${2}001L002_x.MXF"
  echo meta > "$V/$1/XDROOT/Clip/${2}001L001_xM01.XML"
  echo media > "$V/$1/XDROOT/MEDIAPRO.XML"
}
audio_card() { # name
  local n t
  for n in 001 002 010; do
    mkdir -p "$V/$1/${TODAY}_$n.TAKE"
    for t in Tr1 Tr5 TrL_R; do echo "$n$t" > "$V/$1/${TODAY}_$n.TAKE/${TODAY}_${n}_$t.WAV"; done
  done
  mkdir -p "$V/$1/200101_001.TAKE"; echo old > "$V/$1/200101_001.TAKE/200101_001_Tr1.WAV"
}

echo "1. first run without settings"
reset
check "start refuses without a settings file" '! "$TOOL" start P 2>/dev/null'
"$TOOL" init >/dev/null
check "init writes the settings file" '[ -f "$T/config" ]'
check "init does not overwrite" '! "$TOOL" init 2>/dev/null'

echo "2. default settings: whole card, two destinations"
sed -i.bak 's/^DESTINATIONS=.*/DESTINATIONS=("one")/' "$T/config"
sony_card "Untitled" A; audio_card "REC"
check "one destination is refused" '! "$TOOL" start "My Show" 2>/dev/null'
"$TOOL" start "My Show" --to two >/dev/null 2>&1; settle
D="$V/one/My Show/Footage/$ISO/CAMA"
check "clip copied with card structure" '[ -f "$D/XDROOT/Clip/A001L001_x.MXF" ]'
check "sidecar files copied too" '[ -f "$D/XDROOT/MEDIAPRO.XML" ]'
check "second destination has it" '[ -f "$V/two/My Show/Footage/$ISO/CAMA/XDROOT/Clip/A001L002_x.MXF" ]'
check "audio keeps original names" '[ -f "$V/two/My Show/Audio/$ISO/${TODAY}_001.TAKE/${TODAY}_001_Tr1.WAV" ]'
check "old audio take skipped" '[ ! -e "$V/one/My Show/Audio/$ISO/200101_001.TAKE" ]'
check "both jobs passed" '[ "$(grep -l "RESULT: PASS" "$T"/state/*.log | wc -l)" -eq 2 ]'
check "checksum list saved on each destination" '[ "$(ls "$D"/dit-offloader_CAMA_*.md5 "$V/two/My Show/Footage/$ISO/CAMA"/dit-offloader_CAMA_*.md5 | wc -l)" -eq 2 ]'
check "checksum list covers every file" '[ "$(wc -l < "$(ls "$D"/dit-offloader_CAMA_*.md5)")" -eq 4 ]'
check "cards ejected, not renamed" '[ ! -e "$V/Untitled" ] && [ ! -e "$V/REC" ] && [ ! -e "$V/A" ]'

echo "3. clips mode, renaming, three destinations"
reset; mkdir -p "$V/three/deep"
cat > "$T/config" <<CFG
DESTINATIONS=("one")
VIDEO_PATH='{project}-Media/11-Footage/{date}/CAM{cam}'
AUDIO_PATH='{project}-Media/12-Audio/{date}'
DATE_FORMAT='%y%m%d'
VIDEO_MODE="clips"
VIDEO_EXTENSIONS="mxf"
CLIP_FOLDERS=("XDROOT/Clip")
RENAME_CARD="yes"
AUDIO_RENAME="yes"
AUDIO_ROOMTONE="last"
AUDIO_TRACKS="Tr1=Tr1-OH TrL_R=TrLR-Mix"
CFG
sony_card "Untitled" A; sony_card "Untitled 1" B; audio_card "NO NAME"
"$TOOL" start Gemes3 --to two --to "$V/three/deep" >/dev/null 2>&1; settle
F="Gemes3-Media/11-Footage/$TODAY"; A="Gemes3-Media/12-Audio/$TODAY"
check "camera A clips are flat" '[ -f "$V/one/$F/CAMA/A001L001_x.MXF" ] && [ ! -e "$V/one/$F/CAMA/XDROOT" ]'
check "only clips copied" '[ "$(find "$V/one/$F/CAMB" -type f ! -name "dit-offloader_*" | wc -l)" -eq 2 ]'
check "third destination by path" '[ -f "$V/three/deep/$F/CAMB/B001L002_x.MXF" ]'
check "audio renamed with track name" '[ -f "$V/two/$A/${TODAY}_001.TAKE/$TODAY-Gemes3-Tk01-Tr1-OH.WAV" ]'
check "unknown track keeps its name" '[ -f "$V/two/$A/${TODAY}_002.TAKE/$TODAY-Gemes3-Tk02-Tr5.WAV" ]'
check "last take is RoomTone" '[ -f "$V/one/$A/${TODAY}_010.TAKE/$TODAY-Gemes3-RoomTone-TrLR-Mix.WAV" ]'
check "three jobs passed" '[ "$(grep -l "RESULT: PASS" "$T"/state/*.log | wc -l)" -eq 3 ]'
check "all cards ejected" '[ "$(ls "$V" | wc -l)" -eq 3 ]'

echo "4. a damaged copy is caught"
reset; sony_card "Untitled" C
mkdir -p "$V/two/$F/CAMC"; echo different > "$V/two/$F/CAMC/C001L001_x.MXF"
"$TOOL" start Gemes3 --to two >/dev/null 2>&1; settle
check "job reports FAIL" 'grep -q "RESULT: FAIL" "$T"/state/CAMC-*.log'
check "nothing copied when a file differs" '[ ! -e "$V/one/$F/CAMC/C001L001_x.MXF" ]'
check "the differing file is named" 'grep -q "two/$F/CAMC/C001L001_x.MXF" "$T"/state/CAMC-*.log'
check "failed card stays mounted" '[ -d "$V/C" ]'
check "existing file was not overwritten" '[ "$(cat "$V/two/$F/CAMC/C001L001_x.MXF")" = different ]'
check "eject refuses a failed card" '! "$TOOL" eject C 2>/dev/null'

echo "5. options"
reset; sony_card "CARD9" A
"$TOOL" start P --to two --card CARD9 --cam X7 --day 2026-01-02 >/dev/null 2>&1; settle
check "--cam and --day are used" '[ -f "$V/one/P-Media/11-Footage/260102/CAMX7/A001L001_x.MXF" ]'
check "--cam without --card is refused" '! "$TOOL" start P --to two --cam B 2>/dev/null'
check "missing destination is refused" '! "$TOOL" start P --to nowhere 2>/dev/null'
check "version prints" '"$TOOL" --version | grep -q "dit-offloader [0-9]"'

check "commas between drives get a hint" '"$TOOL" start P --to "two,three" 2>&1 | grep -q "not commas"'
check "start without a project is refused" '! "$TOOL" start --to two 2>/dev/null'
reset; sony_card "CARD9" A
echo 'PROJECT="FromSettings"' >> "$T/config"
"$TOOL" start --to two --card CARD9 --day 2026-01-02 >/dev/null 2>&1; settle
check "project comes from the settings" '[ -f "$V/one/FromSettings-Media/11-Footage/260102/CAMA/A001L001_x.MXF" ]'
reset; sony_card "CARD9" A
"$TOOL" start Override --to two --card CARD9 --day 2026-01-02 >/dev/null 2>&1; settle
check "project on the command line wins" '[ -f "$V/one/Override-Media/11-Footage/260102/CAMA/A001L001_x.MXF" ]'

echo "6. rehearse"
reset
"$TOOL" rehearse --to two > "$T/rehearse.out" 2>&1
check "rehearse passes for both fake cards" '[ "$(grep -c "RESULT: PASS" "$T/rehearse.out")" -eq 2 ]'
check "rehearse lists what landed" 'grep -q "DIT-OFFLOADER-TEST-Media/12-Audio/.*RoomTone" "$T/rehearse.out"'

echo "7. identical copies from an earlier run are kept"
reset; sony_card "Untitled" A
cat > "$T/config" <<CFG
DESTINATIONS=("one")
CFG
mkdir -p "$V/one/P/Footage/$ISO/CAMA/XDROOT/Clip"
cp "$V/Untitled/XDROOT/Clip/A001L001_x.MXF" "$V/one/P/Footage/$ISO/CAMA/XDROOT/Clip/"
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "job passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'
check "matching copy is reported" 'grep -q "1 copies are already at a destination and match" "$T"/state/CAMA-*.log'

echo "8. status and stale jobs"
reset; mkdir -p "$T/state"
echo 999999 > "$T/state/CAMQ.pid"; echo "12:00:00  Step 1/3: copying" > "$T/state/CAMQ-20260101-120000.log"
check "unfinished job shows INTERRUPTED" '"$TOOL" status 2>/dev/null | grep -q "CAMQ: INTERRUPTED"'
echo $$ > "$T/state/CAMA.pid"
sony_card "Untitled" A
check "reused pid does not block a new offload" '"$TOOL" start P --to two >/dev/null 2>&1'
settle
check "that offload passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'

echo "9. start reports cards that did not start"
reset; sony_card "Untitled" A; sony_card "MIX" A
head -c 1000 /dev/urandom > "$V/MIX/XDROOT/Clip/B001L001_x.MXF"
check "start exits with an error" '! "$TOOL" start P --to two >/dev/null 2>&1'
settle
check "the good card still passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'

echo "10. audio after midnight"
reset
TOMORROW="$(date -j -v+1d '+%y%m%d' 2>/dev/null || date -d tomorrow '+%y%m%d')"
audio_card "REC"; mkdir -p "$V/REC/${TOMORROW}_001.TAKE"; echo late > "$V/REC/${TOMORROW}_001.TAKE/${TOMORROW}_001_Tr1.WAV"
"$TOOL" start P --to two --overnight >/dev/null 2>&1; settle
check "next-day take copied with --overnight" '[ -f "$V/two/P/Audio/$ISO/${TOMORROW}_001.TAKE/${TOMORROW}_001_Tr1.WAV" ]'
check "audio job passes" 'grep -q "RESULT: PASS" "$T"/state/AUDIO-*.log'

echo "11. free space counts other running offloads"
reset; sony_card "Untitled" A
mkdir -p "$T/state"
need="$(du -sk "$V/Untitled" | cut -f1)"
PATH="$T/dfbin:$PATH" FAKE_FREE_KB=$((need - 50)) "$TOOL" start P --to two >/dev/null 2>&1; settle
check "too little space fails" 'grep -q "not enough free space on /fake drive" "$T"/state/CAMA-*.log'
rm -f "$T"/state/CAMA-*.log
bash -c 'sleep 60; :' _run CAMQ camera Q & other=$!
echo $other > "$T/state/CAMQ.pid"
printf '%s
%s
' "$V/Q" "$V/one/elsewhere" > "$T/state/CAMQ.paths"
printf '%s	%s
' "$V/Q/big.MXF" big.MXF > "$T/state/CAMQ.plan"
echo $((need + 100)) > "$T/state/CAMQ.sizes"
PATH="$T/dfbin:$PATH" FAKE_FREE_KB=$((need * 2)) "$TOOL" start P --to two >/dev/null 2>&1; settle
check "space held by a running offload is counted" 'grep -q "plus running offloads" "$T"/state/CAMA-*.log'
kill $other 2>/dev/null; wait $other 2>/dev/null; rm -f "$T"/state/CAMA-*.log "$T/state/CAMQ".*
PATH="$T/dfbin:$PATH" FAKE_FREE_KB=$((need * 2)) "$TOOL" start P --to two >/dev/null 2>&1; settle
check "enough space passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'

echo "12. progress bars"
reset; mkdir -p "$T/state" "$V/two/P"
head -c 1048576 /dev/zero > "$V/two/P/part.MXF"
bash -c 'sleep 60; :' _run CAMQ camera Q & other=$!
echo $other > "$T/state/CAMQ.pid"
printf '%s\n%s\n%s\n' "$V/Q" "$V/one/P" "$V/two/P" > "$T/state/CAMQ.paths"
printf 'dest\t1\t0\t2048\ndest\t2\t0\t2048\ntotal\t4096\nstep\t2\t%s\n' "$(date +%s)" > "$T/state/CAMQ.progress"
printf '1024\t1024\t%s\n' "$V/Q/clip.MXF" > "$T/state/CAMQ.hash-card"
LC_ALL=C LC_CTYPE=C LANG=C "$TOOL" status > "$T/status.out"
kill $other 2>/dev/null; wait $other 2>/dev/null
check "first copy shows done" 'grep -q "copy to destination 1 *#* 100%" "$T/status.out"'
check "second copy shows bytes arrived" 'grep -q "copy to destination 2 *#*\.* *5[0-9]%" "$T/status.out"'
check "card checksum shows its share" 'grep -q "checksum card *#*\.* *25%" "$T/status.out"'
check "copy checksums are waiting" 'grep -q "checksum destination 2 *waiting" "$T/status.out"'

if command -v xxhsum >/dev/null 2>&1; then
  echo "13. xxHash"
  reset; sony_card "Untitled" A
  echo 'HASH_ALGO="xxh128"' >> "$T/config"
  "$TOOL" start P --to two >/dev/null 2>&1; settle
  check "xxh128 offload passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'
  check "xxh128 checksum list saved" 'ls "$V/two/P/Footage/$ISO/CAMA"/dit-offloader_CAMA_*.xxh128 >/dev/null 2>&1'
fi

echo "14. parallel copying"
reset; mkdir -p "$V/three/deep"
cat > "$T/config" <<CFG
DESTINATIONS=("one")
VIDEO_MODE="clips"
VIDEO_EXTENSIONS="mxf"
CLIP_FOLDERS=("XDROOT/Clip")
AUDIO_RENAME="yes"
AUDIO_ROOMTONE="last"
AUTO_EJECT="no"
COPY_MODE="parallel"
CFG
sony_card "Untitled" A; audio_card "REC"
touch -t 202001020304 "$V/Untitled/XDROOT/Clip/A001L001_x.MXF"
"$TOOL" start P --to two --to "$V/three/deep" >/dev/null 2>&1; settle
P1="P/Footage/$ISO/CAMA"
check "both jobs pass" '[ "$(grep -l "RESULT: PASS" "$T"/state/*.log | wc -l)" -eq 2 ]'
check "log says parallel" 'grep -q "Copying to all 3 destinations at once" "$T"/state/CAMA-*.log'
check "clip on all three destinations" '[ -f "$V/one/$P1/A001L001_x.MXF" ] && [ -f "$V/two/$P1/A001L002_x.MXF" ] && [ -f "$V/three/deep/$P1/A001L001_x.MXF" ]'
check "copies match the card" 'cmp -s "$V/Untitled/XDROOT/Clip/A001L001_x.MXF" "$V/three/deep/$P1/A001L001_x.MXF"'
check "renamed audio on all three" '[ -f "$V/three/deep/P/Audio/$ISO/${TODAY}_010.TAKE/$ISO-P-RoomTone-TrL-R.WAV" ]'
check "no partial files left" '[ -z "$(find "$V" -name "*.dit-part")" ]'
check "modification date kept" '[ "$(find "$V/two/$P1/A001L001_x.MXF" -newermt "2020-01-03" | wc -l)" -eq 0 ]'
check "cards left mounted with AUTO_EJECT=no" '[ -d "$V/Untitled" ] && [ -d "$V/REC" ]'

reset; sony_card "Untitled" A
"$TOOL" start P --to two --staged >/dev/null 2>&1; settle
check "--staged overrides the settings" 'grep -q "Step 1/3" "$T"/state/CAMA-*.log'
check "staged run passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'

reset; sony_card "Untitled" A
mkdir -p "$V/one/$P1"; cp "$V/Untitled/XDROOT/Clip/A001L001_x.MXF" "$V/one/$P1/"
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "matching copy kept in parallel mode" 'grep -q "1 copies are already at a destination and match" "$T"/state/CAMA-*.log'
check "and the job passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'

# A tee that damages one copy: the check of that copy must catch it.
REAL_TEE="$(command -v tee)"; mkdir -p "$T/teebin"
cat > "$T/teebin/tee" <<SHIM
#!/bin/bash
"$REAL_TEE" "\$@"; rc=\$?
for last; do :; done
echo X >> "\$last"
exit \$rc
SHIM
chmod +x "$T/teebin/tee"
reset; sony_card "Untitled" A
PATH="$T/teebin:$PATH" "$TOOL" start P --to two >/dev/null 2>&1; settle
check "damaged copy fails the job" 'grep -q "RESULT: FAIL" "$T"/state/CAMA-*.log'
check "the damaged destination is named" 'grep -q "destination 2 does NOT match" "$T"/state/CAMA-*.log'
check "card stays mounted" '[ -d "$V/Untitled" ]'

echo "15. checksum files"
reset; sony_card "Untitled" A
cat > "$T/config" <<CFG
DESTINATIONS=("one")
VIDEO_MODE="clips"
CLIP_FOLDERS=("XDROOT/Clip")
CHECKSUM_FILE="mhl"
CFG
"$TOOL" start P --to two >/dev/null 2>&1; settle
M="$(find "$V/two/$P1" -maxdepth 1 -name "CAMA_*.mhl" | head -1)"
check "classic MHL saved on each destination" '[ -n "$M" ] && ls "$V/one/$P1"/CAMA_*.mhl >/dev/null 2>&1'
check "MHL lists every clip" '[ "$(grep -c "<md5>" "$M")" -eq 2 ]'
check "MHL checksum is right" 'grep -q "<md5>$(md5 -q "$V/two/$P1/A001L001_x.MXF" 2>/dev/null || md5sum < "$V/two/$P1/A001L001_x.MXF" | cut -d" " -f1)</md5>" "$M"'
check "MHL is well-formed XML" '! command -v xmllint >/dev/null || xmllint --noout "$M"'
[ -z "$MHL11_XSD" ] || check "MHL matches the MHL 1.1 schema" 'xmllint --noout --schema "$MHL11_XSD" "$M" 2>/dev/null'
check "no plain list with CHECKSUM_FILE=mhl" '! ls "$V/two/$P1"/dit-offloader_* >/dev/null 2>&1'
echo 'HASH_ALGO="sha256"' >> "$T/config"
check "classic MHL refuses sha256" '"$TOOL" start P --to two 2>&1 | grep -q "CHECKSUM_FILE=ascmhl"'

if command -v xxhsum >/dev/null 2>&1; then
  reset; sony_card "Untitled" A
  sed -i.bak 's/^HASH_ALGO=.*/HASH_ALGO="xxh64"/' "$T/config"
  "$TOOL" start P --to two >/dev/null 2>&1; settle
  M="$(find "$V/one/$P1" -maxdepth 1 -name "CAMA_*.mhl" | head -1)"
  check "xxh64 goes in MHL as xxhash64be" '[ "$(grep -c "<xxhash64be>" "$M")" -eq 2 ]'
  [ -z "$MHL11_XSD" ] || check "xxh64 MHL matches the schema" 'xmllint --noout --schema "$MHL11_XSD" "$M" 2>/dev/null'

  reset; sony_card "Untitled" A
  sed -i.bak 's/^CHECKSUM_FILE=.*/CHECKSUM_FILE="ascmhl"/; s/^HASH_ALGO=.*/HASH_ALGO="xxh128"/' "$T/config"
  echo 'COPY_MODE="parallel"' >> "$T/config"
  "$TOOL" start P --to two >/dev/null 2>&1; settle
  H="$V/two/$P1/ascmhl"
  check "ASC MHL generation 1 saved" 'ls "$H"/0001_CAMA_*.mhl >/dev/null 2>&1'
  check "ASC MHL chain saved" 'grep -q "sequencenr=\"1\"" "$H/ascmhl_chain.xml"'
  check "ASC MHL lists every clip as original" '[ "$(grep -c "<xxh128 action=\"original\"" "$H"/0001_*.mhl)" -eq 2 ]'
  # A second card from camera A on the same day lands in the same folder.
  mkdir -p "$V/CARD2/XDROOT/Clip"; head -c 5000 /dev/urandom > "$V/CARD2/XDROOT/Clip/A002L001_x.MXF"
  sleep 1
  "$TOOL" start P --to two --card CARD2 >/dev/null 2>&1; settle
  check "second offload adds generation 2" 'ls "$H"/0002_CAMA_*.mhl >/dev/null 2>&1 && grep -q "sequencenr=\"2\"" "$H/ascmhl_chain.xml"'
  check "generation 1 left as it was" '[ "$(grep -c "<hash>" "$H"/0001_*.mhl)" -eq 2 ]'
  if [ -n "$ASCMHL_XSD" ]; then
    for g in "$H"/0001_*.mhl "$H"/0002_*.mhl; do
      check "$(basename "$g") matches the ASC MHL schema" 'xmllint --noout --schema "$ASCMHL_XSD" "$g" 2>/dev/null'
    done
    check "chain matches the ASC MHL directory schema" 'xmllint --noout --schema "$ASCMHL_DIR_XSD" "$H/ascmhl_chain.xml" 2>/dev/null'
  fi
  if command -v ascmhl >/dev/null 2>&1; then
    check "the ASC MHL reference tool verifies the history" 'ascmhl create -h xxh128 "$V/two/$P1" >/dev/null 2>&1 && ls "$H"/0003_*.mhl >/dev/null 2>&1 && ! grep -q "action=\"failed\"" "$H"/0003_*.mhl'
  fi
fi

echo "16. clear"
reset; sony_card "Untitled" A; sony_card "Untitled 1" B
cat > "$T/config" <<CFG
DESTINATIONS=("one")
CFG
mkdir -p "$V/two/P/Footage/$ISO/CAMB/XDROOT/Clip"; echo different > "$V/two/P/Footage/$ISO/CAMB/XDROOT/Clip/B001L001_x.MXF"
"$TOOL" start P --to two >/dev/null 2>&1; settle
bash -c 'sleep 60; :' _run CAMQ camera Q & other=$!
echo $other > "$T/state/CAMQ.pid"
"$TOOL" clear > "$T/clear.out"
check "passed job cleared" 'grep -q "Cleared CAMA (PASS)" "$T/clear.out" && ! "$TOOL" status 2>/dev/null | grep -q "CAMA:"'
check "failed job kept" 'grep -q "CAMB(FAIL)" "$T/clear.out" && "$TOOL" status 2>/dev/null | grep -q "CAMB: FAILED"'
check "running job kept" 'grep -q "Still running, not cleared: CAMQ" "$T/clear.out"'
check "records moved to the archive" '[ -n "$(find "$T/state/archive" -name "CAMA-*.log")" ]'
"$TOOL" clear --all >/dev/null
check "--all clears the failed job" '! "$TOOL" status 2>/dev/null | grep -q "CAMB:"'
kill $other 2>/dev/null; wait $other 2>/dev/null
"$TOOL" clear --all >/dev/null
check "nothing left says so" '"$TOOL" clear | grep -q "Nothing to clear"'

echo "17. settings template"
"$TOOL" init --print > "$T/template"
for name in PROJECT DESTINATIONS MIN_DESTINATIONS VIDEO_PATH AUDIO_PATH DATE_FORMAT VIDEO_MODE \
            VIDEO_EXTENSIONS CLIP_FOLDERS CAMERA_MARKERS CAM_SOURCE RENAME_CARD AUDIO_ENABLED \
            AUDIO_TAKE_SUFFIX AUDIO_RENAME AUDIO_NAME AUDIO_TAKE_LABEL AUDIO_ROOMTONE AUDIO_TRACKS \
            COPY_MODE HASH_ALGO CHECKSUM_FILE AUTO_EJECT WATCH_ON_START SHOOT_DAY DAY_STARTS_AT \
            DAY_CHECK AUDIO_TAKES SOURCE_RECHECK KEEP_FILE_INFO TERMINAL_ALERTS REPORT_FORMAT \
            REPORT_PATH; do
  check "template describes $name" 'grep -Eq "^# ([A-Z_]+ and )?$name[ :]" "$T/template" && grep -q "^#\{0,1\}$name=" "$T/template"'
done
check "every setting in the template is one the tool reads" '[ -z "$(grep -o "^#\{0,1\}[A-Z_]*=" "$T/template" | tr -d "#=" | while read -r v; do grep -q "^$v=" "$TOOL" || echo "$v"; done)" ]'
check "init --print does not create a file" '[ ! -e "$T/config.never" ] && DIT_OFFLOADER_CONFIG="$T/config.never" "$TOOL" init --print >/dev/null && [ ! -e "$T/config.never" ]'

echo "18. progress bars in parallel mode"
reset; mkdir -p "$T/state" "$V/two/P"
head -c 1048576 /dev/zero > "$V/two/P/part.MXF"
bash -c 'sleep 60; :' _run CAMQ camera Q & other=$!
echo $other > "$T/state/CAMQ.pid"
printf '%s\n%s\n%s\n' "$V/Q" "$V/one/P" "$V/two/P" > "$T/state/CAMQ.paths"
printf 'dest\t1\t0\t2048\ndest\t2\t0\t2048\ntotal\t4096\nmode\tparallel\nstep\t1\t%s\n' "$(date +%s)" > "$T/state/CAMQ.progress"
printf '1024\t1024\t%s\n' "$V/Q/clip.MXF" > "$T/state/CAMQ.hash-card"
printf '1024\t1024\t%s\n' "$V/two/P/clip.MXF" > "$T/state/CAMQ.hash-dest2"
LC_ALL=C LC_CTYPE=C LANG=C "$TOOL" status > "$T/status.out"
kill $other 2>/dev/null; wait $other 2>/dev/null
check "header says everything runs at once" 'grep -q "copying and checksumming at the same time" "$T/status.out"'
check "second copy shows bytes arrived" 'grep -q "copy to destination 2 *#*\.* *5[0-9]%" "$T/status.out"'
check "copy checksums run, not waiting" 'grep -q "checksum destination 2 *#*\.* *25%" "$T/status.out" && ! grep -q waiting "$T/status.out"'

echo "19. progress bars right after start"
reset; sony_card "Untitled" A
cat > "$T/config" <<CFG
DESTINATIONS=("one")
COPY_MODE="parallel"
WATCH_ON_START="yes"
CFG
"$TOOL" start P --to two > "$T/start.out" 2>&1; settle
check "without a terminal it says so instead of flooding" 'grep -q "no terminal. Use ssh -t" "$T/start.out"'
check "and the offload passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'
printf 'DESTINATIONS=("one")\nWATCH_ON_START="maybe"\n' > "$T/config.bad"
check "a bad WATCH_ON_START is refused" 'DIT_OFFLOADER_CONFIG="$T/config.bad" "$TOOL" start P --to two 2>&1 | grep -q "WATCH_ON_START must be yes or no"'

# A slow tee keeps an offload busy long enough to act on it part way.
mkdir -p "$T/slowbin"
printf '#!/bin/bash\nsleep 3\nexec "%s" "$@"\n' "$REAL_TEE" > "$T/slowbin/tee"
chmod +x "$T/slowbin/tee"
if command -v python3 >/dev/null 2>&1; then
  # Run start in a simulated terminal, press Ctrl-C while the bars show, and check that
  # only the watching stops.
  reset; sony_card "Untitled" A
  cat > "$T/press_ctrl_c.py" <<'PYTHON'
import os, pty, select, sys, time
tool, out = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv(tool, [tool, "start", "P", "--to", "two"])
buf, sent, start = b"", False, time.time()
while time.time() - start < 60:
    ready, _, _ = select.select([fd], [], [], 0.5)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
    if not sent and b"copy to destination" in buf:
        time.sleep(0.5)
        os.write(fd, b"\x03")
        sent = True
_, status = os.waitpid(pid, 0)
open(out, "wb").write(buf)
print("sent" if sent else "not-sent", "exited", os.WEXITSTATUS(status))
PYTHON
  PATH="$T/slowbin:$PATH" python3 "$T/press_ctrl_c.py" "$TOOL" "$T/pty.out" > "$T/pty.result"
  check "start shows the progress bars" 'grep -q "copying and checksumming at the same time" "$T/pty.out"'
  check "Ctrl-C stops the watching" 'grep -q "^sent exited" "$T/pty.result"'
  check "the offload was still running after Ctrl-C" '"$TOOL" status 2>/dev/null | grep -q "CAMA: RUNNING"'
  settle
  check "and it finishes and passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'
fi

echo "20. stop"
check "stop with nothing running says so" '"$TOOL" stop --all | grep -q "No offloads are running"'
check "stop of a job that is not running fails" '! "$TOOL" stop B >/dev/null 2>&1'
check "stop needs a job" '! "$TOOL" stop 2>/dev/null'
# Slow copy tools keep offloads busy long enough to stop them part way.
REAL_CP="$(command -v cp)"
mkdir -p "$T/slowcp"
printf '#!/bin/bash\nsleep 4\nexec "%s" "$@"\n' "$REAL_CP" > "$T/slowcp/cp"
chmod +x "$T/slowcp/cp"
for mode in parallel staged; do
  reset; sony_card "Untitled" A
  cat > "$T/config" <<CFG
DESTINATIONS=("one")
COPY_MODE="$mode"
CFG
  if [ $mode = parallel ]; then slow="$T/slowbin"; else slow="$T/slowcp"; fi
  PATH="$slow:$PATH" "$TOOL" start P --to two >/dev/null 2>&1
  sleep 3
  "$TOOL" stop A > "$T/stop.out" 2>&1
  check "$mode: stop reports the job stopped" 'grep -q "Stopped CAMA" "$T/stop.out"'
  check "$mode: nothing of the offload keeps running" '! pgrep -f "_run CAMA " >/dev/null'
  check "$mode: status shows STOPPED" '"$TOOL" status 2>/dev/null | grep -q "CAMA: STOPPED"'
  check "$mode: the log records the stop" 'grep -q "RESULT: STOPPED" "$T"/state/CAMA-*.log'
  check "$mode: card stays mounted" '[ -d "$V/Untitled" ]'
  check "$mode: eject refuses the stopped card" '! "$TOOL" eject A 2>/dev/null'
  check "$mode: no half copy has a real name" '[ -z "$(find "$V/one" "$V/two" -name "*.MXF" -size -100k 2>/dev/null)" ]'
  "$TOOL" start P --to two >/dev/null 2>&1; settle
  check "$mode: starting it again passes" 'grep "RESULT:" "$(ls -t "$T"/state/CAMA-*.log | head -1)" | tail -1 | grep -q PASS'
  check "$mode: and leaves no .dit-part files" '[ -z "$(find "$V/one" "$V/two" -name "*.dit-part")" ]'
done
for mode in staged parallel; do
  reset; sony_card "Untitled" A
  printf 'DESTINATIONS=("one")\nCOPY_MODE="%s"\nAUTO_EJECT="no"\n' $mode > "$T/config"
  mkdir -p "$V/two/P/Footage/$ISO/CAMA/XDROOT/Clip"
  echo "half a copy" > "$V/two/P/Footage/$ISO/CAMA/XDROOT/Clip/A001L001_x.MXF.dit-part"
  "$TOOL" start P --to two >/dev/null 2>&1; settle
  check "$mode: an unfinished copy from before is replaced" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log && cmp -s "$V/Untitled/XDROOT/Clip/A001L001_x.MXF" "$V/two/P/Footage/$ISO/CAMA/XDROOT/Clip/A001L001_x.MXF" && [ -z "$(find "$V/two" -name "*.dit-part")" ]'
done
reset; sony_card "Untitled" A; sony_card "Untitled 1" B
cat > "$T/config" <<CFG
DESTINATIONS=("one")
COPY_MODE="parallel"
CFG
PATH="$T/slowbin:$PATH" "$TOOL" start P --to two >/dev/null 2>&1
sleep 2
"$TOOL" stop --all > "$T/stop.out" 2>&1
check "stop --all stops every running offload" 'grep -q "Stopped CAMA" "$T/stop.out" && grep -q "Stopped CAMB" "$T/stop.out" && ! pgrep -f "dit-offloader _run" >/dev/null'

echo "21. copies are checked from the drive, not from memory"
head -c 20000000 /dev/urandom > "$T/cached.bin"; cat "$T/cached.bin" > /dev/null
check "the helper clears a file from memory" '[ "$(dit-offloader-evict "$T/cached.bin")" -le 1 ]'
check "the helper fails on a missing file" '! dit-offloader-evict "$T/missing.bin" >/dev/null'
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\nCOPY_MODE="parallel"\nAUTO_EJECT="no"\n' > "$T/config"
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "parallel offload passes" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'
check "no copy was checked from memory" '! grep -q "still in memory" "$T"/state/CAMA-*.log'
mkdir -p "$T/noevict"; cp "$T/bin/diskutil" "$T/bin/hdiutil" "$T/noevict/"
check "parallel mode refuses without the helper" 'PATH="$T/noevict:/usr/bin:/bin" "$TOOL" start P --to two 2>&1 | grep -q "needs dit-offloader-evict"'

echo "22. second read of the card (SOURCE_RECHECK)"
# A tee that changes the data it reads, as a faulty reader would: every copy gets the same
# wrong data, so only a second read of the card can notice.
mkdir -p "$T/badread"
printf '#!/bin/bash\ntr a b | "%s" "$@"\n' "$REAL_TEE" > "$T/badread/tee"
chmod +x "$T/badread/tee"
for recheck in no yes; do
  reset; sony_card "Untitled" A
  printf 'DESTINATIONS=("one")\nCOPY_MODE="parallel"\nAUTO_EJECT="no"\nSOURCE_RECHECK="%s"\n' $recheck > "$T/config"
  PATH="$T/badread:$PATH" "$TOOL" start P --to two >/dev/null 2>&1; settle
  if [ $recheck = no ]; then
    check "without it, a bad read goes unnoticed (why it exists)" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'
  else
    check "with it, the card is read again" 'grep -q "Reading the card a second time" "$T"/state/CAMA-*.log'
    check "and the bad read fails the offload" 'grep -q "RESULT: FAIL" "$T"/state/CAMA-*.log && grep -q "different data when read a second time" "$T"/state/CAMA-*.log'
  fi
done
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\nCOPY_MODE="parallel"\nSOURCE_RECHECK="yes"\n' > "$T/config"
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "a good card passes the second read" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log'

echo "23. status headings and summary"
reset; sony_card "Untitled" A; sony_card "Untitled 1" B
printf 'DESTINATIONS=("one")\n' > "$T/config"
mkdir -p "$V/two/P/Footage/$ISO/CAMB/XDROOT/Clip"; echo different > "$V/two/P/Footage/$ISO/CAMB/XDROOT/Clip/B001L001_x.MXF"
"$TOOL" start P --to two >/dev/null 2>&1; settle
"$TOOL" status > "$T/status.out" 2>&1
check "a passed card says PASSED" 'grep -q "===== CAMA: PASSED =====" "$T/status.out"'
check "a failed card says FAILED" 'grep -q "===== CAMB: FAILED =====" "$T/status.out"'
check "a summary line counts them" 'grep -q "^Summary: 1 passed .* 1 NOT passed: CAMB (FAILED)" "$T/status.out"'
check "no colour codes when not in a terminal" '! grep -q "$(printf "\033")" "$T/status.out"'

echo "24. wait and Terminal alerts"
check "wait with nothing running says so" '"$TOOL" wait | grep -q "No offloads are running"'
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\nCOPY_MODE="parallel"\n' > "$T/config"
PATH="$T/slowbin:$PATH" "$TOOL" start P --to two >/dev/null 2>&1
"$TOOL" wait > "$T/wait.out" 2>&1; rc=$?
check "wait waits for the offload" 'grep -q "Waiting for: CAMA" "$T/wait.out" && grep -q "CAMA PASSED" "$T/wait.out"'
check "wait ends with the summary and exit status 0" 'grep -q "ALL 1 PASSED: CAMA" "$T/wait.out" && [ $rc = 0 ]'
check "no bell or title without a terminal" '! grep -q "$(printf "\a")" "$T/wait.out" && ! grep -q "$(printf "\033]0;")" "$T/wait.out"'
reset; sony_card "Untitled" C
mkdir -p "$V/two/P/Footage/$ISO/CAMC/XDROOT/Clip"; echo different > "$V/two/P/Footage/$ISO/CAMC/XDROOT/Clip/C001L001_x.MXF"
printf 'DESTINATIONS=("one")\n' > "$T/config"
"$TOOL" start P --to two >/dev/null 2>&1
"$TOOL" wait > "$T/wait.out" 2>&1; rc=$?
check "wait exits 1 when one did not pass" 'grep -q "NOT PASSED: CAMC (FAILED)" "$T/wait.out" && [ $rc = 1 ]'
if command -v python3 >/dev/null 2>&1; then
  reset; sony_card "Untitled" A
  printf 'DESTINATIONS=("one")\nCOPY_MODE="parallel"\nTERMINAL_ALERTS="bell title summary"\n' > "$T/config"
  PATH="$T/slowbin:$PATH" "$TOOL" start P --to two >/dev/null 2>&1
  python3 "$T/drive.py" -- "$TOOL" wait > "$T/wait.out" 2>&1
  check "in a terminal, the bell rings when a card passes" 'grep -q "$(printf "\a")" "$T/wait.out"'
  check "and the title shows the counts" 'grep -q "dit-offloader: 0 running, 1 passed, 0 not passed" "$T/wait.out"'
fi
printf 'DESTINATIONS=("one")\nTERMINAL_ALERTS="bell sirens"\n' > "$T/config"
check "an unknown alert is refused" '"$TOOL" start P --to two 2>&1 | grep -q "TERMINAL_ALERTS takes"'

echo "25. a lock left by a stopped offload"
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\n' > "$T/config"
mkdir -p "$T/state/space.lock"; echo 999999 > "$T/state/space.lock/pid"
start_time=$(date +%s)
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "a stale lock is cleared at once" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log && ! grep -q "held the free space check" "$T"/state/CAMA-*.log && [ $(( $(date +%s) - start_time )) -lt 60 ]'
check "and no lock is left behind" '[ ! -e "$T/state/space.lock" ]'

echo "26. file information (KEEP_FILE_INFO)"
if [ "$(uname)" = Darwin ]; then
  for mode in staged parallel; do
    for keep in yes no; do
      reset; sony_card "Untitled" A
      f="$V/Untitled/XDROOT/Clip/A001L001_x.MXF"
      touch -t 202001020304 "$f"; touch -t 202103040506 "$f"     # created 2020, modified 2021
      xattr -w com.example.dit "kept" "$f"
      printf 'DESTINATIONS=("one")\nCOPY_MODE="%s"\nKEEP_FILE_INFO="%s"\nAUTO_EJECT="no"\n' $mode $keep > "$T/config"
      "$TOOL" start P --to two >/dev/null 2>&1; settle
      c="$V/two/P/Footage/$ISO/CAMA/XDROOT/Clip/A001L001_x.MXF"
      if [ $keep = yes ]; then
        check "$mode, yes: creation date kept" '[ "$(stat -f %B "$c")" = "$(stat -f %B "$f")" ]'
        check "$mode, yes: Finder information kept" '[ "$(xattr -p com.example.dit "$c" 2>/dev/null)" = kept ]'
      else
        check "$mode, no: creation date is the modification date" '[ "$(stat -f %B "$c")" = "$(stat -f %m "$f")" ]'
      fi
      check "$mode, $keep: modification date kept" '[ "$(stat -f %m "$c")" = "$(stat -f %m "$f")" ]'
    done
  done
else
  echo "  (creation dates and Finder information exist on macOS only; checked there)"
fi

echo "27. clear --purge"
mkdir -p "$T/state/archive/20200101-000000" "$T/state/archive/fresh"
touch -t 202001010000 "$T/state/archive/20200101-000000"
"$TOOL" clear --purge 30 > "$T/purge.out"
check "old archived records are deleted" '[ ! -e "$T/state/archive/20200101-000000" ] && grep -q "Deleted 1 archived" "$T/purge.out"'
check "recent ones are kept" '[ -d "$T/state/archive/fresh" ]'
check "--purge needs a number" '! "$TOOL" clear --purge soon 2>/dev/null'

echo "28. offload report"
reset; sony_card "Untitled" A; sony_card "Untitled 1" B; audio_card "REC"
printf 'DESTINATIONS=("one")\nREPORT_FORMAT="html text"\nREPORT_PATH="{project}/Reports"\nAUTO_EJECT="no"\n' > "$T/config"
mkdir -p "$V/two/P/Footage/$ISO/CAMB/XDROOT/Clip"; echo different > "$V/two/P/Footage/$ISO/CAMB/XDROOT/Clip/B001L001_x.MXF"
"$TOOL" start P --to two >/dev/null 2>&1; settle
R="$V/one/P/Reports/${ISO}_P_offload-report"
check "text and HTML reports on every destination" '[ -f "$R.txt" ] && [ -f "$R.html" ] && [ -f "$V/two/P/Reports/${ISO}_P_offload-report.html" ]'
check "the report counts passes and failures" 'grep -q "3 offloads: 2 passed, 1 FAILED (CAMB)" "$R.txt"'
sum="$(md5 -q "$V/Untitled/XDROOT/Clip/A001L001_x.MXF" 2>/dev/null || md5sum < "$V/Untitled/XDROOT/Clip/A001L001_x.MXF" | cut -d" " -f1)"
check "the report lists each file with its checksum" '[ -n "$sum" ] && grep -q "A001L001_x.MXF .*$sum" "$R.txt"'
check "the report says why a card failed before copying" 'grep -q "Why: files already at a destination differ from the card" "$R.txt"'
check "the HTML report marks the failure" 'grep -q "class=\"fail\">FAIL" "$R.html"'
cat > "$T/tags.py" <<'PYTHON'
import html.parser, sys
class Tags(html.parser.HTMLParser):
    VOID = {"meta", "br", "img", "link", "input", "hr"}
    def __init__(self):
        super().__init__(); self.open, self.bad = [], 0
    def handle_starttag(self, tag, attrs):
        if tag not in self.VOID: self.open.append(tag)
    def handle_endtag(self, tag):
        if self.open and self.open[-1] == tag: self.open.pop()
        else: self.bad += 1
t = Tags(); t.feed(open(sys.argv[1], encoding="utf-8").read())
sys.exit(1 if t.open or t.bad else 0)
PYTHON
check "the HTML report's tags all match up" '! command -v python3 >/dev/null || python3 "$T/tags.py" "$R.html"'
check "report shows it in Terminal" '"$TOOL" report P | grep -q "3 offloads: 2 passed, 1 FAILED"'
check "report says when there is nothing" '"$TOOL" report Nope | grep -q "No offloads recorded"'
printf 'DESTINATIONS=("one")\nREPORT_FORMAT="pdf"\n' > "$T/config"
check "an unknown report format is refused" '"$TOOL" start P --to two 2>&1 | grep -q "REPORT_FORMAT takes"'

echo "29. shoot day"
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\nSHOOT_DAY="cutoff"\nDAY_STARTS_AT="23:59"\nDAY_CHECK="off"\n' > "$T/config"
YESTERDAY="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d yesterday '+%Y-%m-%d')"
if [ "$(date '+%H%M')" -lt 2359 ]; then
  "$TOOL" start P --to two >/dev/null 2>&1; settle
  check "cutoff: before the new day starts, it is the previous day" '[ -d "$V/one/P/Footage/$YESTERDAY/CAMA" ]'
fi
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\nSHOOT_DAY="cutoff"\nDAY_STARTS_AT="00:00"\n' > "$T/config"
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "cutoff: after it, today" '[ -d "$V/one/P/Footage/$ISO/CAMA" ]'
reset; sony_card "Untitled" A
find "$V/Untitled" -type f -exec touch -t 202512311200 {} +
printf 'DESTINATIONS=("one")\nSHOOT_DAY="clips"\n' > "$T/config"
"$TOOL" start P --to two > "$T/start.out" 2>&1; settle
check "clips: the card's own date" '[ -d "$V/one/P/Footage/2025-12-31/CAMA" ] && grep -q "from the card" "$T/start.out"'
reset; sony_card "Untitled" A
find "$V/Untitled" -type f -exec touch -t 202512311200 {} +
printf 'DESTINATIONS=("one")\n' > "$T/config"
"$TOOL" start P --to two > "$T/start.out" 2>&1; settle
check "DAY_CHECK=warn: notes the mismatch" 'grep -q "is dated 2025-12-31 (2), not the shoot day $ISO" "$T/start.out"'
check "and goes ahead" 'grep -q "RESULT: PASS" "$T"/state/CAMA-*.log && [ -d "$V/one/P/Footage/$ISO/CAMA" ]'
reset; sony_card "Untitled" A
find "$V/Untitled" -type f -exec touch -t 202512311200 {} +
printf 'DESTINATIONS=("one")\nDAY_CHECK="stop"\n' > "$T/config"
"$TOOL" start P --to two > "$T/start.out" 2>&1; settle
check "DAY_CHECK=stop: does not start the card" 'grep -q "not started (DAY_CHECK=stop)" "$T/start.out" && [ ! -e "$T/state/CAMA.pid" ]'
"$TOOL" start P --to two --day 2025-12-31 >/dev/null 2>&1; settle
check "--day settles it" '[ -d "$V/one/P/Footage/2025-12-31/CAMA" ]'
reset; sony_card "Untitled" A
printf 'DESTINATIONS=("one")\nSHOOT_DAY="ask"\n' > "$T/config"
"$TOOL" start P --to two > "$T/start.out" 2>&1; settle
check "ask without a terminal: today, with a note" 'grep -q "no terminal to ask in; using today" "$T/start.out" && [ -d "$V/one/P/Footage/$ISO/CAMA" ]'
if command -v python3 >/dev/null 2>&1; then
  reset; sony_card "Untitled" A
  python3 "$T/drive.py" "Shoot day as YYYY-MM-DD=2025-06-07" -- "$TOOL" start P --to two > "$T/start.out" 2>&1; settle
  check "ask in a terminal: shows the card's dates" 'grep -q "Untitled: $ISO (2)" "$T/start.out"'
  check "and uses the day typed" '[ -d "$V/one/P/Footage/2025-06-07/CAMA" ]'
fi

echo "30. audio takes and room tone"
audio_sized() {   # takes 001 and 010 bigger than 002, so 002 is the shortest
  audio_card "$1"
  head -c 200000 /dev/urandom > "$V/$1/${TODAY}_001.TAKE/${TODAY}_001_Tr2.WAV"
  head -c 200000 /dev/urandom > "$V/$1/${TODAY}_010.TAKE/${TODAY}_010_Tr2.WAV"
}
A="P/Audio/$ISO"
rt() {            # roomtone setting, extra start options -> take folder labelled RoomTone
  reset; audio_sized "REC"
  printf 'DESTINATIONS=("one")\nAUDIO_RENAME="yes"\nAUDIO_ROOMTONE="%s"\nAUTO_EJECT="no"\n' "$1" > "$T/config"
  shift
  "$TOOL" start P --to two "$@" > "$T/start.out" 2>&1; settle
  find "$V/one/$A" -name "*RoomTone*" | sed 's|.*/\([^/]*\.TAKE\)/.*|\1|' | sort -u
}
check "first" '[ "$(rt first)" = "${TODAY}_001.TAKE" ]'
check "last" '[ "$(rt last)" = "${TODAY}_010.TAKE" ]'
check "a take number" '[ "$(rt 2)" = "${TODAY}_002.TAKE" ]'
check "shortest" '[ "$(rt shortest)" = "${TODAY}_002.TAKE" ]'
check "none" '[ -z "$(rt none)" ]'
check "--roomtone overrides the setting" '[ -z "$(rt last --roomtone none)" ]'
check "a take that is not there: none, with a note" '[ -z "$(rt 7)" ] && grep -q "take 7 is not among" "$T/start.out"'
check "ask without a terminal: none, with a note" '[ -z "$(rt ask)" ] && grep -q "no take is labelled RoomTone" "$T/start.out"'
check "start shows the takes and the choice" '[ -n "$(rt last)" ] && grep -q "Takes: 3 (${TODAY}_001.TAKE to ${TODAY}_010.TAKE)   RoomTone: ${TODAY}_010.TAKE" "$T/start.out"'
if command -v python3 >/dev/null 2>&1; then
  reset; audio_sized "REC"
  printf 'DESTINATIONS=("one")\nAUDIO_RENAME="yes"\nAUDIO_ROOMTONE="ask"\n' > "$T/config"
  python3 "$T/drive.py" "Which take is the room tone?=10" -- "$TOOL" start P --to two > "$T/start.out" 2>&1; settle
  check "ask in a terminal: lists the takes" 'grep -q "take   2   ${TODAY}_002.TAKE" "$T/start.out"'
  check "and labels the take chosen" '[ -n "$(find "$V/one/$A/${TODAY}_010.TAKE" -name "*RoomTone*")" ]'
fi
# The same takes offloaded again with another choice: refused, so no take is stored twice.
rt last >/dev/null
"$TOOL" start P --to two --roomtone none >/dev/null 2>&1; settle
check "takes already stored under other names are refused" 'grep -q "already on a destination under other names" "$(ls -t "$T"/state/AUDIO-*.log | head -1)"'
check "and nothing new is copied" '[ -z "$(find "$V/one/$A/${TODAY}_010.TAKE" -name "*Tk10*")" ]'
reset; audio_sized "REC"
printf 'DESTINATIONS=("one")\nAUDIO_TAKES="all"\n' > "$T/config"
"$TOOL" start P --to two >/dev/null 2>&1; settle
check "AUDIO_TAKES=all takes every take on the card" '[ -d "$V/one/$A/200101_001.TAKE" ] && [ -d "$V/one/$A/${TODAY}_010.TAKE" ]'
reset; audio_sized "REC"
printf 'DESTINATIONS=("one")\n' > "$T/config"
"$TOOL" start P --to two --day 2024-02-02 > "$T/start.out" 2>&1; settle
check "no takes of the day: not started, with the dates found" 'grep -q "no takes dated 240202 on REC" "$T/start.out" && [ ! -e "$T/state/AUDIO.pid" ]'
if command -v python3 >/dev/null 2>&1; then
  reset; audio_sized "REC"
  printf 'DESTINATIONS=("one")\nAUDIO_TAKES="ask"\n' > "$T/config"
  python3 "$T/drive.py" "Which takes?=200101" -- "$TOOL" start P --to two > "$T/start.out" 2>&1; settle
  check "AUDIO_TAKES=ask: takes the day typed" '[ -d "$V/one/$A/200101_001.TAKE" ] && [ ! -d "$V/one/$A/${TODAY}_001.TAKE" ]'
fi

echo
if [ $fails = 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi
