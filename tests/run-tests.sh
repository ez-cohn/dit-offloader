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
if [ "$1" = attach ]; then n="${2#/tmp/dit-offloader-fake-}"; mkdir -p "$DIT_OFFLOADER_VOLUMES/${n%-*}"; fi
SHIM
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
check "only clips copied" '[ "$(find "$V/one/$F/CAMB" -type f | wc -l)" -eq 2 ]'
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

echo "6. rehearse"
reset
"$TOOL" rehearse --to two > "$T/rehearse.out" 2>&1
check "rehearse passes for both fake cards" '[ "$(grep -c "RESULT: PASS" "$T/rehearse.out")" -eq 2 ]'
check "rehearse lists what landed" 'grep -q "DIT-OFFLOADER-TEST-Media/12-Audio/.*RoomTone" "$T/rehearse.out"'

echo
if [ $fails = 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi
