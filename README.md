# UUP Dump Windows ISO Builder

Docker container that automatically downloads and creates Windows ISO files using [UUP dump](https://uupdump.net).

## Features

- Fetches the latest Windows build from UUP dump on every run
- **Skips the download entirely** if an ISO with the same build number already exists
- Supports Windows 10, Windows 11, and Windows Server 2022
- Configurable language and edition
- Timestamped log written to `/output/uup-dump.log` with automatic rotation
- Unraid-ready with PUID/PGID support and an included Community Applications template

## Quick Start

```bash
docker run --rm \
  -v /path/to/isos:/output \
  -v /path/to/workdir:/work \
  -e WINDOWS_TARGET=windows-11 \
  -e LANGUAGE=de-de \
  -e EDITION=Professional \
  ghcr.io/krx3d/uup-dump-get-latest-windows-iso:latest
```

Or with `docker-compose`:

```bash
# edit docker-compose.yml to set your paths, then:
docker compose run --rm uup-dump-windows-iso
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `WINDOWS_TARGET` | `windows-11` | `windows-11`, `windows-10`, or `windows-2022` |
| `LANGUAGE` | `de-de` | Language pack — `de-de`, `en-us`, `fr-fr`, `es-es`, `it-it`, `pl-pl`, … |
| `EDITION` | `Professional` | `Professional`, `Home`, `ServerStandard`, `ServerDatacenter` |
| `OUTPUT_DIR` | `/output` | Output directory inside the container |
| `WORK_DIR` | `/work` (or `/output/.work`) | Temporary build directory (~30 GB needed during conversion) |
| `PUID` | `99` | UID for output file ownership |
| `PGID` | `100` | GID for output file ownership |

## Output

| File | Description |
|---|---|
| `{major}.{minor}.Vibranium-X64-{LANG}-{EDITION}_Updated.iso` | The finished ISO |
| `{major}.{minor}.Vibranium-X64-{LANG}-{EDITION}_Updated.iso.sha256.txt` | SHA-256 checksum |
| `{major}.{minor}.json` | Build metadata (title, build number, UUP dump ID, …) |
| `uup-dump.log` | Timestamped run log |

Example: `26200.8737.Vibranium-X64-DE-CLIENTPRO_Updated.iso`

## Disk Space

| Location | Space needed |
|---|---|
| `/work` | ~30 GB during build (cleaned up automatically afterwards) |
| `/output` | ~6–8 GB per ISO |

Map `/work` to a fast disk (cache drive on Unraid) to significantly reduce build time.

## Unraid

### Via Community Applications

1. Install the [Community Applications](https://forums.unraid.net/topic/38582-plug-in-community-applications/) plugin.
2. In CA, click **Add Container** and paste the template URL:
   ```
   https://raw.githubusercontent.com/KrX3D/uup-dump-get-latest-windows-iso/main/unraid-template.xml
   ```
3. Set the **ISO Output Path** to your NAS share (e.g. `/mnt/user/isos/windows`).
4. Set the **Work Directory** to a fast cache path (e.g. `/mnt/cache/uup-work`).
5. Click **Apply**.
6. Start the container manually from the Docker tab, or schedule it with the **User Scripts** plugin.

### Scheduling with User Scripts

Use the [User Scripts](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/) plugin to run a monthly check:

```bash
#!/bin/bash
docker run --rm \
  -v /mnt/user/isos/windows:/output \
  -v /mnt/cache/uup-work:/work \
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
6. Renames the ISO, writes a SHA-256 checksum file and a JSON metadata file, then cleans up the work directory.

## Build the Image Locally

```bash
git clone https://github.com/KrX3D/uup-dump-get-latest-windows-iso.git
cd uup-dump-get-latest-windows-iso
docker build -t uup-dump-windows-iso .
```
