# Digital Signage Installer

## Supported baseline

This installer targets:

- Raspberry Pi OS based on Debian GNU/Linux 13 `trixie`
- 64-bit Desktop image
- Wayland session support
- LightDM active
- Read-only HTTP/HTTPS directory listing for slide files

## What this installs

The installer prepares a Raspberry Pi to run as a digital signage device.

It creates a dedicated `signage-user`, installs a custom LightDM Wayland session named `signage-session`, downloads slides from a web directory into a local cache, enables a resilient sync timer, optionally installs a slide-server CA certificate, and ensures OpenSSH Server is installed/running for future maintenance.

It can also install opt-in software update support. When enabled, the Pi can fetch updated signage player software from a trusted Git repository and apply it using the repository's `update-signage.sh` script.

## Repository layout

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
    # signage-update.timer is generated during install from SIGNAGE_AUTO_UPDATE_ONCALENDAR.
  wayland-sessions/
    signage-session.desktop
```

## Basic install

Copy the example configuration file, edit it, and run the installer:

```bash
cp signage.conf.example signage.conf
nano signage.conf
sudo ./install-signage.sh
```

At minimum, set the slide source:

```bash
SLIDES_URL="https://server.local/signage/show1"
```

The URL must expose a plain Apache/Nginx-style directory listing with direct links to image files. The fetcher only considers image links directly inside that directory listing, not nested subdirectories. The installer fails if the URL is unreachable or if no `feh`-readable image files are found.

The installer enables `signage.service` but does not start it or restart LightDM by default. To enter signage mode after installation, reboot the Pi or run:

```bash
sudo systemctl start signage
```

To have the installer restart LightDM and enter signage mode immediately, set this in `signage.conf` before installing:

```bash
RESTART_LIGHTDM_AFTER_INSTALL="1"
```

### Repair mode

The installer refuses to run if signage already appears to be installed or partially installed.

Use repair mode to carefully reinstall program files and service configuration over an existing or damaged install:

```bash
sudo ./install-signage.sh --repair
```

## Basic operation

Use `signagectl` for normal operation.

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

Manually trigger a software update check:

```bash
sudo signagectl update
```

Check service and timer status:

```bash
signagectl status
```

The service is enabled at install time, so a reboot returns the Pi to signage mode even if `sudo signagectl stop` was used for local administration.

Lower-level commands such as `signage-admin-mode`, `signage-kiosk-mode`, `signage-sync`, and `signage-update` are installed as helper commands. Prefer `signagectl` for routine operation.

## Configuration: `signage.conf`

The installer reads local configuration from:

```text
./signage.conf
```

During installation, that file is copied to:

```text
/etc/signage/signage.conf
```

After installation, edit the installed copy if you need to change runtime behavior:

```bash
sudo nano /etc/signage/signage.conf
```

### Required slide source

```bash
SLIDES_URL="https://server.company.com/signage/show1"
```

`SLIDES_URL` is the HTTP/HTTPS directory listing used as the slideshow source.

The URL must expose direct links to image files in the top-level directory listing. The fetcher discovers candidate files by filename extension, does not recurse into nested subdirectories, downloads candidate files, validates them with `feh --list`, and promotes only valid slide sets into the local release cache.

### Playback settings

```bash
SLIDESHOW_DELAY_SECONDS="8"
```

Controls how long each slide is shown during playback.

```bash
IMAGE_EXTENSIONS="png jpg jpeg gif bmp webp tif tiff xpm pnm pbm pgm ppm"
```

Controls which filename extensions are considered candidate slide files when reading the remote directory listing.

Slides are ordered alphabetically by filename. To control playback order, prefix slide filenames with sortable numbers, for example:

```text
001-welcome.png
002-hours.png
003-events.png
```

### Sync, cache, and reload settings

```bash
RESTART_THROTTLE_SECONDS="900"
HTTP_TIMEOUT_SECONDS="30"
KEEP_RELEASES="5"
```

`RESTART_THROTTLE_SECONDS` controls how often the running slideshow may be restarted after new slides are synced. The default is 900 seconds, or 15 minutes.

`HTTP_TIMEOUT_SECONDS` controls HTTP timeout behavior during slide fetches.

`KEEP_RELEASES` controls how many local slide releases are retained under:

```text
/var/lib/signage/releases/
```

The active release is pointed to by:

```text
/var/lib/signage/current
```

The sync timer runs every 5 minutes by default. Failed syncs do not disturb the current local slideshow.

### Optional slide-server CA certificate

If the slide server uses HTTPS with an internal/self-signed CA, provide a URL for a PEM-formatted CA certificate before installing:

```bash
SLIDES_CA_CERT_URL="http://server.company.com/path/to/company-root-ca.crt"
```

The downloaded file must be PEM format and contain `BEGIN CERTIFICATE`.

The installer downloads that certificate, installs it as:

```text
/usr/local/share/ca-certificates/signage-slides-ca.crt
```

Then it runs:

```bash
update-ca-certificates
```

The certificate URL itself must be reachable using existing system trust, or over HTTP.

Uninstall removes the installer-managed certificate and runs `update-ca-certificates` again.

### Install and uninstall display behavior

By default, install does not immediately restart LightDM:

```bash
RESTART_LIGHTDM_AFTER_INSTALL="0"
```

Set this to `1` before installing if the Pi should enter signage mode immediately after installation:

```bash
RESTART_LIGHTDM_AFTER_INSTALL="1"
```

For development cleanup, uninstall can also restart LightDM after removing signage components:

```bash
RESTART_LIGHTDM_AFTER_UNINSTALL="1"
```

Use this only when it is safe for the active graphical session to be interrupted.

### Software update settings

Software updates are opt-in.

```bash
SIGNAGE_AUTO_UPDATE_ENABLED="false"
SIGNAGE_AUTO_UPDATE_REPO_URL=""
SIGNAGE_AUTO_UPDATE_REF="HEAD"
SIGNAGE_AUTO_UPDATE_ONCALENDAR="Tue *-*-* 03:00:00"
SIGNAGE_CONFIG_PRESERVE_KEYS="SLIDES_URL"
```

`SIGNAGE_AUTO_UPDATE_ENABLED="true"` enables the scheduled update timer.

The default schedule checks once a week on Tuesday at 3:00 AM local time.

`SIGNAGE_AUTO_UPDATE_ONCALENDAR` accepts a systemd `OnCalendar` expression.

`SIGNAGE_AUTO_UPDATE_REPO_URL` should point to the Git repository that the Pi should use for software updates, for example:

```bash
SIGNAGE_AUTO_UPDATE_REPO_URL="http://server.local/git/signage-pi.git"
```

`SIGNAGE_AUTO_UPDATE_REF="HEAD"` tracks the default branch advertised by the configured Git repository. You can also set a branch, tag, or other resolvable ref, such as:

```bash
SIGNAGE_AUTO_UPDATE_REF="live"
```

Enabling software updates allows the Pi to download and run code from the configured repository. Use only a trusted repository.

### Config preservation during updates

During a software update, the repository's `signage.conf.example` becomes the new base config.

Values listed in `SIGNAGE_CONFIG_PRESERVE_KEYS` are copied forward from the existing Pi-local file:

```text
/etc/signage/signage.conf
```

The default preserve list is:

```bash
SIGNAGE_CONFIG_PRESERVE_KEYS="SLIDES_URL"
```

This prevents an update from replacing the Pi's slide URL with a generic or fleet-default value.

Add additional keys to the preserve list if they should remain Pi-local across software updates.

## Software updates

Software updates are disabled unless explicitly enabled in `signage.conf`.

When scheduled updates are enabled, the Pi periodically fetches software from the configured Git repository and applies it using the repository's `update-signage.sh` script.

To manually trigger a software update check:

```bash
sudo signagectl update
```

Manual update checks require `SIGNAGE_AUTO_UPDATE_REPO_URL` to be set. They do not require the scheduled update timer to be enabled.

Scheduled updates require:

```bash
SIGNAGE_AUTO_UPDATE_ENABLED="true"
```

Use only a trusted update repository. The update system downloads code from the configured repository and runs the repository's updater script as part of the update process.

## Runtime behavior

- Slides are fetched from `SLIDES_URL`.
- Candidate files are discovered by filename extension.
- Downloaded files are validated with `feh --list`.
- Valid slides are promoted to `/var/lib/signage/releases/<timestamp>`.
- `/var/lib/signage/current` points to the active local release.
- Playback uses `/var/lib/signage/current/.playlist.txt`.
- Slides are ordered alphabetically by filename.
- Sync runs every 5 minutes by default.
- The sync timer also schedules a new run 5 minutes after the timer itself is restarted, preventing a stopped/restarted timer from becoming stuck in `active (elapsed)`.
- Slideshow restarts are throttled according to `RESTART_THROTTLE_SECONDS`.
- Failed syncs do not disturb the current local slideshow.

## LightDM and signage mode behavior

The installer adds a `signage.service` kiosk-mode controller.

It does not run `feh` directly. Instead, it toggles LightDM between the signage autologin session and the normal graphical login screen.

When signage mode is started or stopped, the controller terminates only local graphical sessions reported by `loginctl` as `x11` or `wayland`, then restarts LightDM. This logs out any active desktop GUI session so the signage session owns the display cleanly.

SSH sessions and local text TTY sessions are not targeted.

This installer backs up:

```text
/etc/lightdm/lightdm.conf
```

to:

```text
/var/lib/signage/state/lightdm.conf.pre-signage
```

It then sets the active `[Seat:*]` values directly in `/etc/lightdm/lightdm.conf`:

```ini
autologin-user=signage-user
autologin-user-timeout=0
user-session=signage-session
autologin-session=signage-session
```

This is intentional.

On Raspberry Pi OS, the stock `/etc/lightdm/lightdm.conf` may already contain an `autologin-user` or session value for the setup user. A drop-in file under `/etc/lightdm/lightdm.conf.d/` may not win if the main config file is read later or already contains conflicting seat values.

After install, verify the effective LightDM configuration with:

```bash
sudo lightdm --show-config | grep -E 'autologin-user|user-session|autologin-session'
```

Uninstall restores the backed-up LightDM config file if the backup exists.

## SSH readiness

Install ensures OpenSSH Server is installed, enabled, and running:

```bash
systemctl status ssh
```

It also writes this installer-owned drop-in so password authentication is permitted for future remote maintenance:

```text
/etc/ssh/sshd_config.d/99-signage-password-auth.conf
```

Uninstall removes that drop-in and reloads SSH.

The uninstaller does not automatically remove `openssh-server`, even if signage installed it, because SSH may be the active maintenance path.

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

## Logs and troubleshooting

For a high-level status view:

```bash
signagectl status
```

Check the kiosk controller:

```bash
systemctl status signage.service
journalctl -u signage.service -n 100 --no-pager
```

Check slide sync:

```bash
systemctl status signage-sync.timer
systemctl status signage-sync.service
journalctl -u signage-sync.service -n 100 --no-pager
```

Check software updates:

```bash
systemctl status signage-update.timer
systemctl status signage-update.service
journalctl -u signage-update.service -n 100 --no-pager
```

Inspect the active local slideshow:

```bash
ls -l /var/lib/signage/current
cat /var/lib/signage/current/.playlist.txt
```

Inspect retained slide releases:

```bash
ls -l /var/lib/signage/releases
```

Signage-owned logs and state may also be present under:

```text
/var/log/signage/
/var/lib/signage/state/
```

## Uninstall

Run:

```bash
sudo ./uninstall-signage.sh
```

It removes signage program files, disables the sync timer and signage controller, removes `signage-user` if installer state says the user was created by signage, removes the signage SSH drop-in, removes the optional signage CA certificate, restores the backed-up LightDM config, and purges `feh`.

It also removes other non-SSH packages that the installer recorded as absent before installation.

Normal uninstall preserves local configuration and slideshow cache where practical.

To remove all signage-owned config, cache, state, and logs, use purge mode:

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
