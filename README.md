# UUP Dump Windows ISO Builder

Docker container that automatically downloads and creates Windows ISO files using [UUP dump](https://uupdump.net).

## Features

- Fetches the latest Windows build from UUP dump on every run
- **Skips the download entirely** if an ISO with the same build number already exists
- Supports Windows 10, Windows 11, and Windows Server 2022
- Configurable update ring (stable, insider, canary, …), language, and edition
- Rolling `uup-dump.log` plus a timestamped per-run log, both in a configurable log directory
- Temporary build files (~30 GB) go to a dedicated `/work` volume — the ISO share stays clean
- Unraid-ready with PUID/PGID support and an included Community Applications template

## Quick Start

```bash
docker run --rm \
  -v /path/to/isos:/output \
  -e WINDOWS_TARGET=windows-11 \
  -e LANGUAGE=de-de \
  -e EDITION=Professional \
  ghcr.io/krx3d/uup-dump-get-latest-windows-iso:latest
```

Or with `docker-compose`:

```bash
# edit docker-compose.yml to set your path, then:
docker compose run --rm uup-dump-windows-iso
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `WINDOWS_TARGET` | `windows-11` | `windows-11`, `windows-10`, or `windows-2022` |
| `WINDOWS_RING` | `RETAIL` | Update ring/channel — see table below |
| `LANGUAGE` | `de-de` | Language pack — `de-de`, `en-us`, `fr-fr`, `es-es`, `it-it`, `pl-pl`, … |
| `EDITION` | `Professional` | `Professional`, `Home`, `ServerStandard`, `ServerDatacenter` |
| `WORK_DIR` | `/work` | Temp build area inside the container — see Disk Space below |
| `LOG_DIR` | _(same as output)_ | Separate directory for log files (container path `/logs`) |
| `PUID` | `99` | UID for output file ownership (Unraid default: `99` = nobody) |
| `PGID` | `100` | GID for output file ownership (Unraid default: `100` = users) |

### WINDOWS_RING

Controls which Windows Update ring is selected when multiple builds are available.

| Value | Description |
|---|---|
| `RETAIL` | Current stable / general availability release **(default)** |
| `RP` | Release Preview — near-final builds, typically a few weeks ahead of RETAIL |
| `BETA` | Beta Channel insider builds — new features under active testing |
| `DEV` | Dev Channel insider builds — newer features, less stable than BETA |
| `CANARY` | Canary Channel — bleeding-edge, may be highly unstable |
| `ANY` | The absolute newest build regardless of ring |

Every run logs the 15 newest matching builds so you can see what rings and version numbers are currently available before changing this setting.

## Output

ISOs and metadata are always written to `/output`. Log files go to `LOG_DIR` (defaults to `/output`):

| File | Description |
|---|---|
| `{major}.{minor}.Vibranium-X64-{LANG}-{EDITION}_Updated.iso` | The finished ISO |
| `{major}.{minor}.Vibranium-X64-{LANG}-{EDITION}_Updated.iso.sha256.txt` | SHA-256 checksum |
| `{major}.{minor}.json` | Build metadata (title, build number, UUP dump ID, …) |
| `uup-dump.log` | Rolling log — last ~4000 lines across all runs, blank-line separated between runs |
| `YYYY-MM-DD_HH-mm-ss_{build}_{target}_{lang}_{edition}.log` | Per-run log including full aria2/converter output |

Example: `26200.8737.Vibranium-X64-DE-CLIENTPRO_Updated.iso`

## Disk Space

Make sure the volume mapped to `/output` has at least **~35 GB free** before running:

| Purpose | Space |
|---|---|
| Temporary build files (`/work` inside the container) | ~30 GB (deleted automatically when done) |
| Final ISO in `/output` | ~6–8 GB |

Temp files go to `WORK_DIR` (default `/work`) inside the container's writable layer — no extra volume needed if your Docker data is already on the cache SSD.

If you want temp files on a separate share, add a volume mapping (e.g. host `/mnt/cache/uup-work` → container `/work-ext`) and set `WORK_DIR=/work-ext`.

## Unraid

### Via Community Applications

1. Install the [Community Applications](https://forums.unraid.net/topic/38582-plug-in-community-applications/) plugin.
2. In CA, click **Add Container** and paste the template URL:
   ```
   https://raw.githubusercontent.com/KrX3D/uup-dump-get-latest-windows-iso/main/unraid-template.xml
   ```
3. Set the **ISO Output Path** to a share with at least 35 GB free (e.g. `/mnt/user/isos/windows`).
4. Click **Apply**.
5. Start the container manually from the Docker tab, or schedule it with the **User Scripts** plugin.

### Scheduling with User Scripts

Use the [User Scripts](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/) plugin to run a monthly check:

```bash
#!/bin/bash
docker run --rm \
  -v /mnt/user/isos/windows:/output \
  -e WINDOWS_TARGET=windows-11 \
  -e LANGUAGE=de-de \
  -e EDITION=Professional \
  -e PUID=99 \
  -e PGID=100 \
  ghcr.io/krx3d/uup-dump-get-latest-windows-iso:latest
```

Schedule: `0 2 1 * *` (first of every month at 02:00).

## How It Works

1. Queries `api.uupdump.net` for the latest build matching your target, language, and edition.
2. Checks `/output` for any file named `{major}.{minor}.*.iso` — if found, exits immediately.
3. Downloads the UUP conversion package (a zip with download scripts and a converter) from `uupdump.net`.
4. Configures `ConvertConfig.ini` (`AutoExit=1`, `SkipWinRE=1`, etc.) and enables the standard Store app list.
5. Runs `uup_download_linux.sh` (bundled in the package) which downloads Windows Update packages via aria2 and converts them to an ISO using wimlib + genisoimage.
6. Renames the ISO, writes a SHA-256 checksum and JSON metadata file, then removes `/output/.work`.

## Build the Image Locally

```bash
git clone https://github.com/KrX3D/uup-dump-get-latest-windows-iso.git
cd uup-dump-get-latest-windows-iso
docker build -t uup-dump-windows-iso .
```
