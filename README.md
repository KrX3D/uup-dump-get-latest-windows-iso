# UUP Dump Windows ISO Builder

Docker container that automatically downloads and creates Windows ISO files using [UUP dump](https://uupdump.net).

## Features

- Fetches the latest Windows build from UUP dump on every run
- **Skips the download entirely** if an ISO with the same build number already exists
- Supports Windows 10, Windows 11, and Windows Server 2022
- Configurable update ring (stable, insider, canary, …), language, and edition
- **Web UI mode** — interactive configuration page to select target, version, ConvertConfig options, Store apps, and trigger builds from the browser
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

## Web UI Mode

Set `MODE=web` to start a configuration web server instead of building on container start. Open `http://<host>:8080` in your browser to:

- Select OS (Windows 10 / 11 / Server 2022), ring, language, and edition
- Browse and pin a specific build version from the live UUP dump build list
- Toggle all ConvertConfig.ini options with descriptions
- Select which Store apps to include (41 apps, individual toggles)
- Enable/disable SHA-256 checksum and JSON metadata file generation
- Save settings (persisted to `/config/settings.json`)
- Start a build and watch the log output in real time

```bash
docker run -d \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /path/to/isos:/output \
  -v /path/to/config:/config \
  -e MODE=web \
  ghcr.io/krx3d/uup-dump-get-latest-windows-iso:latest
```

Settings saved in the web UI are also used by auto mode — configure once in the web UI, then switch back to `MODE=auto` for scheduled runs.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MODE` | `auto` | `auto` = build on start; `web` = serve the configuration UI on `WEB_PORT` |
| `WEB_PORT` | `8080` | HTTP port for the web UI (only used when `MODE=web`) |
| `WINDOWS_TARGET` | `windows-11` | `windows-11`, `windows-10`, or `windows-2022` |
| `WINDOWS_RING` | `RETAIL` | Update ring/channel — see table below |
| `LANGUAGE` | `de-de` | Language pack — `de-de`, `en-us`, `fr-fr`, `es-es`, `it-it`, `pl-pl`, … |
| `EDITION` | `Professional` | `Professional`, `Home`, `ServerStandard`, `ServerDatacenter` |
| `WORK_DIR` | `/work` | Temp build area inside the container — see Disk Space below |
| `LOG_DIR` | _(same as output)_ | Separate directory for log files (container path `/logs`) |
| `PUID` | `99` | UID for output file ownership (Unraid default: `99` = nobody) |
| `PGID` | `100` | GID for output file ownership (Unraid default: `100` = users) |

> When `MODE=web`, the target/ring/language/edition env vars serve as startup defaults only — the web UI overrides them once settings are saved.

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
| `{major}.{minor}.Vibranium-X64-{LANG}-{EDITION}_Updated.iso.sha256.txt` | SHA-256 checksum (can be disabled) |
| `{major}.{minor}.json` | Build metadata — title, build number, UUP dump ID, … (can be disabled) |
| `uup-dump.log` | Rolling log — last ~4000 lines across all runs, blank-line separated between runs |
| `YYYY-MM-DD_HH-mm-ss_{build}_{target}_{lang}_{edition}.log` | Per-run log including full aria2/converter output |

Example: `26200.8737.Vibranium-X64-DE-CLIENTPRO_Updated.iso`

## Volumes

| Container path | Purpose |
|---|---|
| `/output` | ISO output and log files |
| `/logs` | Log files when `LOG_DIR` is a separate mount |
| `/work` | Temp build files (~30 GB, deleted automatically) |
| `/config` | `settings.json` and live build log for the web UI — mount to persist settings across restarts |

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
4. Set the **Config Directory** to an appdata path (e.g. `/mnt/user/appdata/uup-dump-windows-iso`).
5. Click **Apply**.
6. Start the container manually from the Docker tab, or schedule it with the **User Scripts** plugin.

For web UI mode: set **Mode** to `web`, map port `8080`, change the restart policy in **Extra Parameters** from `--restart=no` to `--restart=unless-stopped`, then start the container and open `http://<unraid-ip>:8080`.

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

**Auto mode:**

1. Queries `api.uupdump.net` for the latest build matching your target, language, and edition.
2. Checks `/output` for any file named `{major}.{minor}.*.iso` — if found, exits immediately.
3. Downloads the UUP conversion package (a zip with download scripts and a converter) from `uupdump.net`.
4. Applies `ConvertConfig.ini` settings (AutoExit, SkipWinRE, NetFx3, etc.) and configures the Store app list — both driven by `/config/settings.json` if present, otherwise defaults.
5. Runs `uup_download_linux.sh` (bundled in the package) which downloads Windows Update packages via aria2 and converts them to an ISO using wimlib + genisoimage.
6. Renames the ISO, optionally writes a SHA-256 checksum and JSON metadata file, then removes the work directory.

**Web UI mode:**

1. Starts an HTTP server on `WEB_PORT` (default 8080).
2. UI queries UUP dump API live to list available builds for the selected OS/ring.
3. On "Start Build", saves settings to `/config/settings.json` and spawns a child build process.
4. Live log output streams to the browser every 2 seconds; status badge updates to done/failed when the build exits.

## Build the Image Locally

```bash
git clone https://github.com/KrX3D/uup-dump-get-latest-windows-iso.git
cd uup-dump-get-latest-windows-iso
docker build -t uup-dump-windows-iso .
```
