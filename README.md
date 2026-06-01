# Digital Signage Installer

Target baseline:

- Raspberry Pi OS based on Debian GNU/Linux 13 `trixie`
- 64-bit Desktop image
- Wayland / `rpd-labwc`
- LightDM active
- Read-only HTTP/HTTPS directory listing for slide files

This installer creates a dedicated `signage-user`, configures a custom LightDM Wayland session named `signage-session`, downloads slides from a web directory into a local cache, and enables a 5-minute sync timer.

## Layout

```text
install-signage.sh
uninstall-signage.sh
signage.conf.example
files/
  bin/
    signage-session
    start-signage
  lib/
    signage-fetch.py
  sbin/
    signage-sync
  systemd/
    signage-sync.service
    signage-sync.timer
  wayland-sessions/
    signage-session.desktop
```

## Basic use

```bash
cp signage.conf.example signage.conf
nano signage.conf
sudo ./install-signage.sh
```

At minimum, set:

```bash
SLIDES_URL="https://server.company.com/signage/show1"
```

The URL must expose a plain Apache/Nginx-style directory listing with direct links to image files. The installer fails if the URL is unreachable or if no `feh`-readable image files are found.

## Uninstall

```bash
sudo ./uninstall-signage.sh
```

The uninstaller is intended for development iteration. It removes the signage files, disables the sync timer, removes `signage-user`, removes the LightDM autologin drop-in, and purges `feh`. It also removes any other required package that the installer recorded as absent before installation.

## Runtime behavior

- Slides are fetched from `SLIDES_URL`.
- Candidate files are discovered by filename extension.
- Downloaded files are validated with `feh --list`.
- Valid slides are promoted to `/var/lib/signage/releases/<timestamp>`.
- `/var/lib/signage/current` points to the active local release.
- Playback uses `/var/lib/signage/current/.playlist.txt`.
- Slides are ordered alphabetically by filename.
- Sync runs every 5 minutes.
- Slideshow restarts are throttled to no more than once every 15 minutes.
- Failed syncs do not disturb the current local slideshow.

## Installed paths

```text
/etc/signage/signage.conf
/etc/lightdm/lightdm.conf.d/50-signage-autologin.conf
/etc/systemd/system/signage-sync.service
/etc/systemd/system/signage-sync.timer
/usr/share/wayland-sessions/signage-session.desktop
/usr/local/bin/signage-session
/usr/local/bin/start-signage
/usr/local/sbin/signage-sync
/usr/local/lib/signage/signage-fetch.py
/var/lib/signage/
/home/signage-user/
```

## Notes

The installer does not restart LightDM by default. Reboot the Pi, or set this in `signage.conf` before installing if you want the installer to restart LightDM immediately:

```bash
RESTART_LIGHTDM_AFTER_INSTALL="1"
```

For development cleanup, you may also set:

```bash
RESTART_LIGHTDM_AFTER_UNINSTALL="1"
```
