# dit-offloader

Verified camera and audio card offloads for macOS, from the command line.

It copies each card to two or more destinations, then re-reads the card and every
copy and compares checksums. It runs in the background, so it works over SSH on a
slow connection and keeps going if you disconnect.

> **Check before you format.** This is a young tool. Only erase a card after its
> offload shows `RESULT: PASS`, and spot-check the copies yourself. The software
> comes with no warranty (see [LICENSE](LICENSE)).

## What it does

- Finds the camera and audio cards that are plugged in.
- Works out each camera's id from the clip filenames (`A001C001.MXF` is camera A),
  or from the card's drive name.
- Copies into a folder layout you define, such as `Project/Footage/2026-11-16/CAMA/`.
- Copies the whole card, or only the video clips into one flat folder.
- Verifies every file on every destination with MD5, SHA-1, SHA-256, xxHash64 or xxHash128.
- Copies in stages, or in parallel: the card read once, written to every destination at
  the same time and checksummed in that same read, with each copy checked as it lands.
- Saves the checksums next to the copies on every destination, so the proof travels
  with the footage: as a plain list, a classic MHL, or an ASC MHL history.
- Never deletes or overwrites a file. If a file with the same name already exists
  and differs, the offload stops before copying anything.
- Checks free space before copying, counting what other running offloads still need.
- Ejects a card once it has passed.
- Optionally renames audio files, for example
  `261116_001_Tr1.WAV` to `261116-Project-Tk01-Tr1-Boom.WAV`.

## Install

```sh
brew install ez-cohn/tap/dit-offloader
```

Requires macOS. Homebrew also installs `xxhash`, used when `HASH_ALGO` is `xxh64` or
`xxh128`, and builds `dit-offloader-evict`, a small helper that makes every check read
the copy from the drive rather than from memory (see "How verification works").

## Quick start

```sh
dit-offloader init        # creates ~/.config/dit-offloader/config
```

Open that file and set `DESTINATIONS` to your drive names. Then practice with two
small fake cards, which touches no real card:

```sh
dit-offloader rehearse --to "SecondDrive"
```

For a real shoot, plug in the cards and run:

```sh
dit-offloader start MyProject --to "SecondDrive"
dit-offloader status --watch
```

With `WATCH_ON_START="yes"` in the settings (or `start --watch`), `start` goes straight on
to show the progress bars. Ctrl-C stops watching; the offloads keep running. That needs a
terminal window: over SSH, connect first or use `ssh -t host dit-offloader start`.
To stop an offload rather than the watching, use `dit-offloader stop`.

While an offload runs, `status` shows a progress bar for each copy and each checksum,
with speed and time left. `status --watch` updates those bars in place every 2 seconds
until the offloads finish (Ctrl-C stops watching; the offloads keep running):

```
===== CAMA: RUNNING =====
  step 3 of 3, 13s into this step
  copy to destination 1    ████████████████████████ 100%  8.0 GB of 8.0 GB
  copy to destination 2    ████████████████████████ 100%  8.0 GB of 8.0 GB
  checksum card            ████████████████████████ 100%  8.0 GB of 8.0 GB
  checksum destination 1   █████████████░░░░░░░░░░░  56%  4.5 GB of 8.0 GB  357.6 MB/s, about 9s left
  checksum destination 2   █████████████░░░░░░░░░░░  56%  4.5 GB of 8.0 GB  357.2 MB/s, about 9s left
```

## Commands

| Command | What it does |
|---|---|
| `init [--print]` | Create the settings file, with every setting described. `--print` shows it instead, without touching your settings |
| `config` | Show the settings in use |
| `list` | Show mounted drives and which ones look like cards |
| `start [project]` | Offload every recognised card. Without a project name, uses `PROJECT` from the settings |
| `status [--all] [--watch]` | Show progress bars and results (last 24 hours, or everything). `--watch` keeps the screen updated until the offloads finish |
| `eject <job>` | Eject a passed card by hand, e.g. `eject A` or `eject AUDIO` |
| `wait` | Wait until the running offloads finish, then say how they ended. Exit status 0 when all passed |
| `report [project] [--day YYYY-MM-DD] [--html]` | Show the offload report of a project and day |
| `stop <job>` / `stop --all` | Stop a running offload, e.g. `stop A` or `stop AUDIO`. The card stays mounted and is not ejected; start it again to offload it |
| `clear [--all] [--purge DAYS]` | Clear finished offloads from `status`. Failed and interrupted ones stay unless you add `--all`. Their records move to `~/.local/state/dit-offloader/archive`; `--purge 30` deletes those archived more than 30 days ago |
| `rehearse` | Practice run with fake cards. Accepts `--to`, `--parallel` and `--staged` |

Options for `start`:

| Option | Meaning |
|---|---|
| `--to <drive>` | Extra destination for this run: a drive name or a full path. Repeatable. |
| `--card <name>` | Offload only this card |
| `--cam <id>` | Camera id for that card, instead of working it out |
| `--day YYYY-MM-DD` | The shoot day, whatever `SHOOT_DAY` says |
| `--roomtone <which>` | The take to label RoomTone: `none`, `ask`, `last`, `first`, `shortest` or a take number, whatever `AUDIO_ROOMTONE` says |
| `--overnight` | Also take audio takes dated the day after the shoot day, for shoots past midnight |
| `--parallel` / `--staged` | Copy in parallel or in stages for this run, whatever `COPY_MODE` says |
| `--watch` / `--no-watch` | Show the progress bars right after starting, or don't, whatever `WATCH_ON_START` says |

## Settings

`dit-offloader init` writes a settings file that describes every setting, the values it
accepts and its default. If you already have a settings file, `dit-offloader init --print`
shows the described version without changing yours. The main settings:

| Setting | Default | Meaning |
|---|---|---|
| `PROJECT` | none | Project name used by `start` when none is given on the command line |
| `DESTINATIONS` | none | Drives or folders every offload goes to. Separate them with spaces: `("Drive1" "Drive2")` |
| `MIN_DESTINATIONS` | `2` | Refuse to start with fewer destinations |
| `VIDEO_PATH` | `{project}/Footage/{date}/CAM{cam}` | Folder layout for video |
| `AUDIO_PATH` | `{project}/Audio/{date}` | Folder layout for audio |
| `DATE_FORMAT` | `%Y-%m-%d` | How `{date}` is written |
| `VIDEO_MODE` | `full` | `full` copies the whole card; `clips` copies only clips, flat |
| `VIDEO_EXTENSIONS` | `mxf mp4 mov braw r3d crm mts` | What counts as a clip |
| `CLIP_FOLDERS` | empty | Folders on the card that hold the clips |
| `CAMERA_MARKERS` | common card layouts | Folders that identify a camera card |
| `CAM_SOURCE` | `filename` | Camera id from clip names, or `volume` for the drive name |
| `RENAME_CARD` | `no` | Rename the card's drive to its camera id |
| `AUDIO_RENAME` | `no` | Rename audio files on the copies |
| `AUDIO_TAKES` | `day` | Which takes on an audio card: `day` (the shoot day's), `all` or `ask` |
| `AUDIO_ROOMTONE` | `none` | Which take is labelled RoomTone: `none`, `ask`, `last`, `first`, `shortest` or a take number |
| `SHOOT_DAY` | `today` | Which day `{date}` is: `today`, `cutoff` (see `DAY_STARTS_AT`), `clips` (each card's own date) or `ask` |
| `DAY_STARTS_AT` | `05:00` | With `SHOOT_DAY="cutoff"`, an offload started before this time belongs to the previous day |
| `DAY_CHECK` | `warn` | Compare the shoot day with the dates on each card: `warn`, `stop` or `off` |
| `AUTO_EJECT` | `yes` | Eject a card after it passes |
| `HASH_ALGO` | `md5` | `md5`, `sha1`, `sha256`, `xxh64` or `xxh128` (the xxHash ones are much faster) |
| `COPY_MODE` | `staged` | `staged` or `parallel` (see below) |
| `CHECKSUM_FILE` | `list` | `list`, `mhl`, `ascmhl` or `none` (see below) |
| `SOURCE_RECHECK` | `no` | In parallel mode, read the card a second time and compare (see below) |
| `KEEP_FILE_INFO` | `yes` | Give copies the card file's creation date and any Finder information, not just its modification date |
| `WATCH_ON_START` | `no` | `yes` shows the progress bars right after `start`, as `status --watch` does |
| `TERMINAL_ALERTS` | `summary` | Alerts while watching or waiting: any of `bell`, `title`, `summary`, or `none` |
| `REPORT_FORMAT` | `none` | Offload report: `html`, `text`, both, or `none` (see below) |
| `REPORT_PATH` | `{project}/Reports` | Where the report goes inside each destination |

See [examples](examples) for a complete settings file.

## How verification works

Either way, a card passes only when every file read back from every destination matches
the card's checksum, and every file is written as `<name>.dit-part` and only gets its real
name once complete, so a copy that is cut off never looks finished.

**Staged** (`COPY_MODE="staged"`, the default):

1. The card is copied to the first destination.
2. That copy is copied to the other destinations while the card is checksummed.
3. Every copy is checksummed and compared with the card.

**Parallel** (`COPY_MODE="parallel"`, or `start --parallel`):

- The card is read once. What is read is written to every destination at the same time
  and checksummed on the way, so the card is never read twice.
- Each copied file is checksummed on every destination as soon as it lands, while the
  next file copies.

Parallel is usually faster with fast destinations (SSDs, RAIDs). It can be slower when
several destinations share one spinning disk, because that disk then reads and writes at
once. Time one shoot each way to see which suits your drives.

**Reading from the drive, not memory.** macOS keeps a file it has just written in memory,
so reading a fresh copy straight back can check that memory instead of the drive. Before
each check, dit-offloader has `dit-offloader-evict` push the file out of memory, so the
check reads what is actually on the drive; the log notes any file it could not push out.
Parallel mode needs the helper and will not run without it.

**Reading the card twice.** Staged mode reads the card twice (to copy, then to checksum),
so a card or reader that returns different data on each read is caught. Parallel mode
reads it once; with `SOURCE_RECHECK="yes"` it reads the card a second time after copying
and compares, at the cost of one more read of the card.

## Checksum files

After a card passes, its checksums are saved in each destination folder, chosen with
`CHECKSUM_FILE`:

| Value | What is saved | Checksums it can hold |
|---|---|---|
| `list` (default) | A plain list, `dit-offloader_<job>_<time>.<algo>` | all |
| `mhl` | A classic Media Hash List (version 1.1), `<folder>_<date>_<time>.mhl`, the kind OffShoot and Silverstack write | `md5`, `sha1`, `xxh64` |
| `ascmhl` | An ASC MHL history: an `ascmhl` folder with one generation per offload into that folder, and the chain file | `md5`, `sha1`, `xxh64`, `xxh128` |
| `none` | Nothing (the checksums stay in the logs) | |

The ASC MHL files are tested against the ASC's published schema and with its reference
tool, `ascmhl`. Running `ascmhl create <folder>` later re-checks every file in that folder
against the history and records the check as a new generation.

A log for each offload is kept in `~/.local/state/dit-offloader`. To re-check a copy
from a plain list later, run this in the destination folder:

```sh
md5sum -c dit-offloader_CAMA_*.md5          # md5 (from coreutils)
shasum -a 256 -c dit-offloader_CAMA_*.sha256
xxhsum -c dit-offloader_CAMA_*.xxh128
```

Before copying, files that are already at a destination (from an earlier or interrupted
run) are checked against the card. Matching ones are kept. If any differ, the offload
stops and lists them, so you can move them aside.

To stop an offload on purpose, run `dit-offloader stop A` (or `AUDIO`, or `--all`).
`status` then shows it as `STOPPED`, and the card is not ejected.

If an offload ends before it finishes for any other reason (the Mac slept, lost power, or
the process was killed), `status` shows it as `INTERRUPTED`.

Either way, do not erase that card; start it again. Any unfinished `.dit-part` copies on
the destinations are replaced by the next run.

## Shoot day, audio takes and room tone

`{date}` in the folder layout is the shoot day, chosen by `SHOOT_DAY`: this Mac's date,
the same with a cutoff time for offloads after midnight, each card's own date (from the
camera's or recorder's clock), or a question. `start --day` always wins. With `DAY_CHECK`,
a card whose dates do not match the shoot day is pointed out (`warn`) or not started
(`stop`), since either a clock or the day may be wrong.

From an audio card, `AUDIO_TAKES` chooses which take folders are offloaded: the shoot
day's, all at the top level of the card, or a question. `AUDIO_ROOMTONE` chooses which
take is labelled RoomTone when files are renamed. If a take is already on a destination
under other names (say an earlier offload labelled it differently), the audio card is not
offloaded, so no take is stored twice.

Questions (`ask`) need a terminal window. Over SSH, connect first, or use `ssh -t`.

## Alerts and reports

While the progress bars are showing, or while `dit-offloader wait` runs, `TERMINAL_ALERTS`
can ring the Terminal bell when a card finishes (three times if it did not pass), show the
counts in the window title, and end with one line saying how they all ended.

With `REPORT_FORMAT`, a report per project and shoot day lists every card with its result,
files, sizes, times, speed and checksums, including cards that failed before copying, with
the reason. It is rebuilt as each card finishes and saved at `REPORT_PATH` on the
destinations, as an HTML page (printable to PDF from a browser) and/or a text file.
`dit-offloader report` shows it in Terminal.

## Using it over SSH

macOS blocks remote logins from reading removable cards until you turn on
**System Settings > General > Sharing > Remote Login > Allow full disk access for
remote users** on the Mac that has the cards.

## Limits

- macOS only.
- Audio support covers recorders that write one folder per take, named `YYMMDD_NNN`
  plus a suffix (`.TAKE` by default). Other recorder layouts are not recognised yet;
  open an issue with a sample folder listing.
- Camera cards are recognised by the folders in `CAMERA_MARKERS`. A card with another
  layout can still be offloaded with `--card`.
- If every camera uses the same clip names (for example `C0001.MP4`), set
  `CAM_SOURCE="volume"` and name the cards, or pass `--card` and `--cam`.

## Development

```sh
tests/run-tests.sh
```

The tests build the helper with `cc`, make fake cards in a temporary folder and use
stand-ins for the macOS disk tools, so they touch no real drive. To use the tool from a
checkout without Homebrew, build the helper next to it:

```sh
cc -O2 -o bin/dit-offloader-evict src/dit-offloader-evict.c
```

## License

MIT
