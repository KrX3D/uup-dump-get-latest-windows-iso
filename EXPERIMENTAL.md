# EXPERIMENTAL: WinPE/DISM update integration

Branch: `experimental/winpe-dism-updates` — **not merged into `main`, not part of the
default image.** This is a testbed for making "Include Windows Updates" actually work.

## Why this branch exists

On `main`, the container converts UUP files to an ISO using wimlib on Linux. wimlib has
no equivalent to DISM's `/Add-Package` servicing, so `AddUpdates`/`ResetBase` in
ConvertConfig.ini are silently no-ops there (confirmed against uup-dump's own FAQ — see
the WARN the main image now logs when those options are checked). This branch works
around that by:

1. Building the ISO exactly as `main` does.
2. Extracting the ISO's own `sources\boot.wim` (a real WinPE — the same environment
   Windows Setup itself boots into, and the one you'd normally reach via Shift+F10 to
   run DISM manually).
3. Injecting a small automation script into it that mounts the offline `install.wim`
   and runs real `dism.exe /Add-Package` with the SSU + LCU update packages already
   downloaded alongside the UUP set.
4. Booting that patched boot.wim in a throwaway QEMU/KVM VM to actually run DISM.
5. Splicing the serviced `install.wim` back into a copy of the original ISO.

If any step fails, or the required devices aren't available, it logs a warning and
falls back to the unpatched ISO — the normal build should never break because of this.

## Requirements beyond the main image

- The Docker **host** must have KVM available (on Unraid: enabled by default if your
  CPU supports virtualization — Settings → VM Manager should be usable).
- The container needs `/dev/kvm` and `/dev/fuse` passed through, plus the
  `SYS_ADMIN` capability (needed for wimlib's FUSE-based mount of `boot.wim`).

## Installing on Unraid without touching your existing setup

This pulls a separately-tagged image (`:experimental-winpe-dism-updates`), built from
this branch by CI — it does not touch the `:latest` image your current container uses.

**Manual container (recommended, most reliable):**

1. Docker tab → **Add Container**.
2. Repository: `ghcr.io/krx3d/uup-dump-get-latest-windows-iso:experimental-winpe-dism-updates`
3. Add these under **Extra Parameters**: `--device=/dev/kvm --device=/dev/fuse --cap-add=SYS_ADMIN`
4. Add volumes for `/output`, `/logs`, `/config` like the normal template (use different
   host paths than your existing container so you don't mix experimental and stable ISOs).
5. Environment variables: the usual `WINDOWS_TARGET` / `LANGUAGE` / `EDITION` / etc.,
   plus **`EXPERIMENTAL_WINPE_UPDATES=1`**.
6. In the web UI (or settings.json) check **"Include Windows Updates."** Without this,
   the new step doesn't run at all — behavior is identical to `main`.

**Via template XML:** `unraid-template.experimental.xml` in this branch has all of the
above pre-filled — point Unraid's "Template Repositories" at
`https://raw.githubusercontent.com/KrX3D/uup-dump-get-latest-windows-iso/experimental/winpe-dism-updates/unraid-template.experimental.xml`
if you'd rather not fill the fields by hand.

## Reading the results

- `winpe-dism-run.log` is written to your Log Directory — this is the actual DISM
  output from inside the VM (mount, add-package, cleanup, unmount). Check this first
  if something goes wrong.
- The main `uup-dump.log` has `[WinPE]`-prefixed lines tracing every step (package
  discovery, boot.wim index chosen, VM boot, splice result).
- Check the built ISO's `install.wim` build number afterward (e.g. via
  `dism /Get-WimInfo` or mounting it) to confirm the UBR now matches what you picked.

## Known unknowns — please report back on these

This has not been run end-to-end on real hardware yet. Specifically uncertain:

1. **Which image index in `boot.wim` is plain WinPE** (honors `winpeshl.ini`) vs.
   "Windows Setup" (may launch `setup.exe` regardless). The code picks by name
   heuristically and logs what it found — if the VM boots straight into Setup instead
   of running DISM, this is why.
2. **Update package naming** — the code looks for `SSU-*.cab` and `*KB<number>*.msu|.cab`
   under `UUPs/`, matching uup-dump's own Windows converter (`convert-UUP.cmd`). If your
   target/ring downloads packages named differently, detection will fail (logged clearly,
   falls back to unpatched).
3. **Whether boot.wim's bundled `dism.exe` has everything it needs** for `/Add-Package`
   on very new/Insider builds specifically.
4. **Timing** — DISM offline servicing can take a while; the VM step currently times
   out at 20 minutes and kills itself if it hangs. May need tuning.
5. **The `xorriso -boot_image any replay -map ...` calls** used to splice `boot.wim`
   and `install.wim` back into a copy of the ISO while preserving bootability — this is
   the documented xorriso pattern for in-place ISO edits, but hasn't been verified
   against this specific ISO layout. If the final ISO doesn't boot, start here.

If you hit a failure, the most useful thing to send back is `winpe-dism-run.log` plus
the `[WinPE]` lines from `uup-dump.log` for that run.
