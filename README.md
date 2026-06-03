# Digital Signage Installer

Target baseline:

- Raspberry Pi OS based on Debian GNU/Linux 13 `trixie`
- 64-bit Desktop image
- Wayland / `rpd-labwc`
- LightDM active
- Read-only HTTP/HTTPS directory listing for slide files

This installer creates a dedicated `signage-user`, configures a custom LightDM Wayland session named `signage-session`, optionally installs a slide-server CA certificate, downloads slides from a web directory into a local cache, enables a resilient 5-minute sync timer, and ensures OpenSSH Server is installed/running for future maintenance.

## Layout

```text
install-signage.sh
uninstall-signage.sh
signage.conf.example
files/
  bin/
    signage-session
    signagectl
    start-signage
  lib/
    signage-fetch.py
  sbin/
    signage-admin-mode
    signage-kiosk-mode
    signage-sync
    signage-update
  systemd/
    signage.service
    signage-sync.service
    signage-sync.timer
    signage-update.service
  wayland-sessions/
    signage-session.desktop
```

## Basic use

```bash
cp signage.conf.example signage.conf
nano signage.conf
sudo ./install-signage.sh
```

The installer refuses to run if signage already appears to be installed or partially installed. Use repair mode to carefully reinstall program files and service configuration over an existing or damaged install:

```bash
sudo ./install-signage.sh --repair
```

At minimum, set:

```bash
SLIDES_URL="https://server.company.com/signage/show1"
```

The URL must expose a plain Apache/Nginx-style directory listing with direct links to image files. The installer fails if the URL is unreachable or if no `feh`-readable image files are found.

If the slide server uses HTTPS with an internal/self-signed CA, provide a URL for a PEM-formatted CA certificate before installing:

```bash
SLIDES_CA_CERT_URL="http://server.company.com/path/to/company-root-ca.crt"
```

The installer downloads that certificate, installs it as `/usr/local/share/ca-certificates/signage-slides-ca.crt`, runs `update-ca-certificates`, and then performs the initial slide sync. The certificate URL itself must be reachable using existing system trust, or over HTTP.

## Controlling signage mode

The installer adds a `signage.service` kiosk-mode controller. It does not run `feh` directly; it toggles LightDM between the signage autologin session and the normal graphical login screen.

When signage mode is started or stopped, the controller terminates only local graphical sessions reported by `loginctl` as `x11` or `wayland`, then restarts LightDM. This logs out any active desktop GUI session so the signage session owns the display cleanly. SSH sessions and local text TTY sessions are not targeted.

Stop the slideshow and return to the graphical login screen:

```bash
sudo signagectl stop
```

Start the slideshow again:

```bash
sudo signagectl start
```

Restart kiosk mode:

```bash
sudo signagectl restart
```

Run a slide sync immediately and restart the display if signage mode is active:

```bash
sudo signagectl reload
```

Check service and timer status:

```bash
signagectl status
```

The service is enabled at install time, so a reboot returns the Pi to signage mode even if `sudo signagectl stop` was used for local administration.


## Software updates

Software updates are opt-in. When enabled, the Pi can fetch updated signage player software from a trusted Git repository and apply it using the repository's `update-signage.sh` script.

Set these values in `signage.conf` before installing, or edit `/etc/signage/signage.conf` later:

```bash
SIGNAGE_AUTO_UPDATE_ENABLED="false"
SIGNAGE_AUTO_UPDATE_REPO_URL=""
SIGNAGE_AUTO_UPDATE_REF="HEAD"
SIGNAGE_AUTO_UPDATE_ONCALENDAR="Tue *-*-* 03:00:00"
SIGNAGE_CONFIG_PRESERVE_KEYS="SLIDES_URL"
```

`SIGNAGE_AUTO_UPDATE_ENABLED="true"` enables the scheduled update timer. The default schedule checks once a week on Tuesday at 3:00 AM local time. `SIGNAGE_AUTO_UPDATE_ONCALENDAR` accepts a systemd `OnCalendar` expression.

`SIGNAGE_AUTO_UPDATE_REPO_URL` should point to the Git repository that the Pi should use for software updates, for example:

```bash
SIGNAGE_AUTO_UPDATE_REPO_URL="http://server.local/git/signage-pi.git"
```

`SIGNAGE_AUTO_UPDATE_REF="HEAD"` tracks the default branch advertised by the configured Git repository. You can also set a branch, tag, or other resolvable ref, such as `live`, `main`, or `stable`.

Enabling software updates allows the Pi to download and run code from the configured repository. Use only a trusted repository.

To manually trigger a software update check:

```bash
sudo signagectl update
```

Manual update checks require `SIGNAGE_AUTO_UPDATE_REPO_URL` to be set. They do not require the scheduled update timer to be enabled.

### Config preservation during updates

During a software update, the repository's `signage.conf.example` becomes the new base config. Values listed in `SIGNAGE_CONFIG_PRESERVE_KEYS` are copied forward from the existing Pi-local `/etc/signage/signage.conf`.

The default preserve list is:

```bash
SIGNAGE_CONFIG_PRESERVE_KEYS="SLIDES_URL"
```

This prevents an update from replacing the Pi's slide URL with a generic or fleet-default value. Add additional keys to the preserve list if they should remain Pi-local.

## Uninstall

```bash
sudo ./uninstall-signage.sh
```

The uninstaller is intended for development iteration. It removes signage program files, disables the sync timer and signage controller, removes `signage-user` if installer state says the user was created by signage, removes the signage SSH drop-in, removes the optional signage CA certificate, restores the backed-up LightDM config, and purges `feh`. It also removes other non-SSH packages that the installer recorded as absent before installation.

Normal uninstall preserves local configuration and slideshow cache where practical. To remove all signage-owned config, cache, state, and logs, use purge mode:

```bash
sudo ./uninstall-signage.sh --purge
```

If the installer state file is missing, uninstall switches to cautious manual mode. Each cleanup step is briefly described and requires `y`, `n`, or `a`:

```text
y = run the described step
n = skip the described step
a = abort uninstall immediately
```

The uninstaller does not automatically remove `openssh-server`, even if signage installed it, because SSH may be the active maintenance path. It does remove signage's SSH password-authentication drop-in.

## Runtime behavior

- Slides are fetched from `SLIDES_URL`.
- Candidate files are discovered by filename extension.
- Downloaded files are validated with `feh --list`.
- Valid slides are promoted to `/var/lib/signage/releases/<timestamp>`.
- `/var/lib/signage/current` points to the active local release.
- Playback uses `/var/lib/signage/current/.playlist.txt`.
- Slides are ordered alphabetically by filename.
- Sync runs every 5 minutes. The timer also schedules a new run 5 minutes after the timer itself is restarted, preventing a stopped/restarted timer from becoming stuck in `active (elapsed)`.
- Slideshow restarts are throttled to no more than once every 15 minutes.
- Failed syncs do not disturb the current local slideshow.

## Installed paths

```text
/etc/signage/signage.conf
/etc/ssh/sshd_config.d/99-signage-password-auth.conf
/usr/local/share/ca-certificates/signage-slides-ca.crt
/etc/lightdm/lightdm.conf
/etc/systemd/system/signage.service
/etc/systemd/system/signage-sync.service
/etc/systemd/system/signage-sync.timer
/etc/systemd/system/signage-update.service
/etc/systemd/system/signage-update.timer
/usr/share/wayland-sessions/signage-session.desktop
/usr/local/bin/signage-session
/usr/local/bin/signagectl
/usr/local/bin/start-signage
/usr/local/sbin/signage-admin-mode
/usr/local/sbin/signage-kiosk-mode
/usr/local/sbin/signage-sync
/usr/local/sbin/signage-update
/usr/local/sbin/update-signage
/usr/local/lib/signage/signage-fetch.py
/var/lib/signage/
/var/log/signage/
/var/lib/signage/state/install.state
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


## SSH readiness

Install ensures OpenSSH Server is installed, enabled, and running:

```bash
systemctl status ssh
```

It also writes this installer-owned drop-in so password authentication is permitted for future remote maintenance:

```text
/etc/ssh/sshd_config.d/99-signage-password-auth.conf
```

Uninstall removes that drop-in and reloads SSH. It leaves `openssh-server` installed by default so uninstall does not accidentally remove the operator's remote access path.

## Optional slide-server CA certificate

Set this in `signage.conf` when the slide URL redirects to HTTPS or uses an internal/self-signed certificate chain:

```bash
SLIDES_CA_CERT_URL="http://server.company.com/path/to/company-root-ca.crt"
```

The downloaded file must be PEM format and contain `BEGIN CERTIFICATE`. Install records the certificate in installer state. Uninstall removes the installer-managed certificate and runs `update-ca-certificates` again.

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
