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
check "failed job kept" 'grep -q "CAMB(FAIL)" "$T/clear.out" && "$TOOL" status 2>/dev/null | grep -q "CAMB: finished"'
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
            COPY_MODE HASH_ALGO CHECKSUM_FILE AUTO_EJECT; do
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

if command -v python3 >/dev/null 2>&1; then
  # Run start in a simulated terminal, press Ctrl-C while the bars show, and check that
  # only the watching stops. A slow tee keeps the offload busy long enough.
  mkdir -p "$T/slowbin"
  printf '#!/bin/bash\nsleep 3\nexec "%s" "$@"\n' "$REAL_TEE" > "$T/slowbin/tee"
  chmod +x "$T/slowbin/tee"
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

echo
if [ $fails = 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi
