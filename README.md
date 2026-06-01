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
    signage-admin-mode
    signage-kiosk-mode
    signage-sync
  systemd/
    signage.service
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

## Controlling signage mode

The installer adds a `signage.service` kiosk-mode controller. It does not run `feh` directly; it toggles LightDM between the signage autologin session and the normal graphical login screen.

Stop the slideshow and return to the graphical login screen:

```bash
sudo systemctl stop signage
```

Start the slideshow again:

```bash
sudo systemctl start signage
```

Restart kiosk mode:

```bash
sudo systemctl restart signage
```

The service is enabled at install time, so a reboot returns the Pi to signage mode even if `sudo systemctl stop signage` was used for local administration.

## Uninstall

```bash
sudo ./uninstall-signage.sh
```

The uninstaller is intended for development iteration. It removes the signage files, disables the sync timer and signage controller, removes `signage-user`, removes the LightDM autologin drop-in, restores the backed-up LightDM config, and purges `feh`. It also removes any other required package that the installer recorded as absent before installation.

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
/etc/lightdm/lightdm.conf
/etc/systemd/system/signage.service
/etc/systemd/system/signage-sync.service
/etc/systemd/system/signage-sync.timer
/usr/share/wayland-sessions/signage-session.desktop
/usr/local/bin/signage-session
/usr/local/bin/start-signage
/usr/local/sbin/signage-admin-mode
/usr/local/sbin/signage-kiosk-mode
/usr/local/sbin/signage-sync
/usr/local/lib/signage/signage-fetch.py
/var/lib/signage/
/var/lib/signage/state/lightdm.conf.pre-signage
/home/signage-user/
```

## Notes

The installer enables `signage.service` but does not start it or restart LightDM by default. Reboot the Pi, run `sudo systemctl start signage`, or set this in `signage.conf` before installing if you want the installer to start signage mode immediately:

```bash
RESTART_LIGHTDM_AFTER_INSTALL="1"
```

For development cleanup, you may also set:

```bash
RESTART_LIGHTDM_AFTER_UNINSTALL="1"
```


## LightDM autologin behavior

This installer backs up `/etc/lightdm/lightdm.conf` to `/var/lib/signage/state/lightdm.conf.pre-signage` and then sets the active `[Seat:*]` values directly in `/etc/lightdm/lightdm.conf`:

```ini
autologin-user=signage-user
autologin-user-timeout=0
user-session=signage-session
autologin-session=signage-session
```

This is intentional. On Raspberry Pi OS, the stock `/etc/lightdm/lightdm.conf` may already contain an `autologin-user` or session value for the setup user. A drop-in file under `/etc/lightdm/lightdm.conf.d/` may not win if the main config file is read later or already contains conflicting seat values.

After install, verify the effective LightDM configuration with:

```bash
sudo lightdm --show-config | grep -E 'autologin-user|user-session|autologin-session'
```

Uninstall restores the backed-up LightDM config file if the backup exists.
