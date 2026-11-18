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
check "unfinished job shows INTERRUPTED" '"$TOOL" status | grep -q "CAMQ: INTERRUPTED"'
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
LANG=C "$TOOL" status > "$T/status.out"
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

echo
if [ $fails = 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi
