# Parsec for ARM64 Linux

Runs the official Parsec Linux client on aarch64 Linux. Parsec only ships an x86-64
build, so this runs it under [Box64](https://github.com/ptitSeb/box64), with a native
ARM64 FFmpeg doing the H.264 decoding. It was built for
[Omarchy](https://omarchy.org) running in a Try Omarchy VM on an Apple silicon Mac,
and should work on other ARM64 distributions too.

This repository holds no Parsec code. `install.sh` downloads the client from
Parsec's own servers when it runs, and you use it under
[Parsec's terms](https://parsec.app/terms).

## Install

```sh
git clone https://github.com/MrSlothuus/parsec-arm64.git
cd parsec-arm64
./install.sh                 # or ./install.sh --mouse-bridge inside a VM, see below
```

You need `git`, `cmake`, `make`, `gcc`, `curl`, `bsdtar` (libarchive) and `python`.
On Arch/Omarchy: `sudo pacman -S --needed base-devel git cmake curl libarchive python`.

The script builds everything in a temporary directory, then installs into
`~/.local` (set `PREFIX` to change that):

| Path | What |
| --- | --- |
| `bin/parsec-native` | Launcher, and the handler for `parsec://` links |
| `opt/parsec-native/` | Box64, FFmpeg, the Parsec client, x86-64 libpng/libjpeg, licenses and `BUILD-INFO.txt` |
| `share/applications/parsec-native.desktop` | App launcher entry, set as the default for `parsec://` |

Run it again to rebuild or update. It doesn't touch any system Box64 you have installed.

## What gets built

- **Box64** at pinned commit `db0873ca`, with one patch
  (`patches/box64-ffmpeg-hw-config.patch`) that wraps `avcodec_get_hw_config`.
  Parsec needs that function to detect FFmpeg 4. The build target is `M1` on Apple
  CPUs and generic `ARM64` everywhere else; set `BOX64_TARGET` (for example
  `RPI5ARM64`) to override it.
- **FFmpeg 4.4.8**, checked against its SHA256 and built natively with only the H.264
  decoder and parser. Box64 passes Parsec's libavcodec calls through to it, so decoding
  runs at native speed. HEVC and hardware decoding are not available.
- **libpng 1.6.37 and libjpeg-turbo 2.1.2** as x86-64 builds from Ubuntu 22.04, each
  checked against a pinned SHA256. They run emulated.

## How the launcher works around Box64

Parsec's in-app updater cannot replace its client library while Box64 has it mapped:
the library ends up empty and the restarted client crashes. So before each start,
`parsec-native`:

1. reads `https://builds.parsec.app/channel/release1/appdata/linux/latest`,
2. downloads that `parsecd-*.so` if it isn't already installed, and accepts it only
   if it matches the SHA256 Parsec publishes,
3. makes the library read-only, so the in-app updater can't truncate it,
4. starts Parsec under Box64.

When you're offline it starts the version already installed. A library that an
earlier session broke gets repaired on the next launch. Logs go to
`~/.local/state/parsec-native/launcher.log`.

## Mouse bridge for VMs (`--mouse-bridge`)

QEMU VMs such as Try Omarchy often have only an absolute pointer (`QEMU Virtio
Tablet`). Once a connection starts, Parsec switches to relative mouse mode and locks
the pointer, and Hyprland neither moves a locked cursor nor turns absolute motion
into relative motion. The result is a mouse that freezes both locally and on the
remote machine.

`parsec-mouse-bridge` fixes this for as long as Parsec runs. The launcher starts it
and it exits along with Parsec. It grabs the tablet, forwards its events through a
virtual copy, and also sends each movement as relative motion on a virtual mouse.
If the bridge dies, the kernel releases the grab and the tablet works directly again.

`--mouse-bridge` also:

- installs `system/70-parsec-mouse-bridge.rules` into `/etc/udev/rules.d/`, which
  gives the logged-in user access to the tablet and `/dev/uinput`,
- loads `uinput` at boot (`system/parsec-mouse-bridge.conf` in `/etc/modules-load.d/`),
- needs `python-evdev`.

The bridge's mouse must not be accelerated or the cursor will drift. In Hyprland's
Lua config (`~/.config/hypr/input.lua` on Omarchy):

```lua
hl.device({ name = "parsec-bridge-mouse", sensitivity = 0, accel_profile = "flat" })
```

or in a classic `hyprland.conf`:

```ini
device {
    name = parsec-bridge-mouse
    sensitivity = 0
    accel_profile = flat
}
```

Parsec's hotkey for releasing the mouse is Ctrl+Alt+Z.

If your tablet has a different name, change `TABLET_NAME` in `bin/parsec-mouse-bridge`
and the name in the udev rule to match.

## Uninstall

```sh
rm -rf ~/.local/opt/parsec-native ~/.local/bin/parsec-native ~/.local/bin/parsec-mouse-bridge \
  ~/.local/share/applications/parsec-native.desktop ~/.local/share/icons/hicolor/256x256/apps/parsec.png
sudo rm -f /etc/udev/rules.d/70-parsec-mouse-bridge.rules /etc/modules-load.d/parsec-mouse-bridge.conf
```

Your Parsec login and settings live in `~/.parsec`.

## License

The scripts in this repository are MIT licensed. Box64 is MIT, FFmpeg is LGPL 2.1,
and libpng and libjpeg-turbo use their own licenses; `install.sh` copies each
license into `opt/parsec-native/licenses/`. Parsec is proprietary software, and
this project is not affiliated with Parsec or Unity.
