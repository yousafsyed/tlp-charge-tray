# Charge Controller

Native Ubuntu tray app for controlling ThinkPad battery charge thresholds with
TLP.

Charge Controller is a small desktop utility for people who keep a ThinkPad
plugged in most of the time and want a quick tray menu for switching between a
battery-preserving charge limit and full-charge mode.

## Features

- Tray indicator for Ubuntu desktop.
- Shows current battery percentage, charging state, and charge thresholds.
- Provides two modes:
  - **Limit to 80%**: sets `BAT0` thresholds to `75/80`.
  - **Charge to 100%**: sets `BAT0` thresholds to `96/100`.
- Uses TLP for battery threshold control.
- Uses Polkit through `pkexec` for privileged changes.
- Installs like a normal Debian package with launcher and login autostart files.

## Supported System

This project currently targets:

- Ubuntu 24.04 desktop.
- Lenovo ThinkPad systems supported by TLP battery care.
- A single battery exposed as `BAT0`.
- TLP 1.6.x or compatible `tlp setcharge` behavior.

Other Linux distributions, desktops, laptop vendors, and multi-battery setups
may need small changes before they work well.

## Install From A Built Package

If you already have a `.deb`, install it with:

```sh
sudo apt install ./charge-controller_0.1.0_amd64.deb
```

If you built it locally with `dpkg-buildpackage`, the package is usually
created one directory above the repository root:

```sh
sudo apt install ../charge-controller_0.1.0_amd64.deb
```

## Build From Source

Install build dependencies:

```sh
sudo apt install build-essential debhelper meson ninja-build valac pkg-config \
  libgtk-3-dev libayatana-appindicator3-dev
```

Install runtime dependencies:

```sh
sudo apt install tlp pkexec policykit-1 gnome-shell-extension-appindicator
```

Build the Debian package:

```sh
dpkg-buildpackage -us -uc -b
```

## Run

```sh
charge-controller
```

You can also launch **Charge Controller** from the app menu. The package
installs an autostart entry so the tray app starts when you log in.

## What It Changes

When a mode is selected, the privileged helper:

- Runs `/usr/sbin/tlp setcharge <start> <stop> BAT0`.
- Creates `/etc/tlp.conf.charge-controller.bak` before the first config change.
- Maintains a marked block at the end of `/etc/tlp.conf`:

```text
# BEGIN charge-controller
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
# END charge-controller
```

The helper only accepts the two built-in modes: `limit-80` and `charge-100`.

## Security And Privacy

- The tray app itself runs as your normal desktop user.
- Root access is limited to the installed helper and mediated by Polkit.
- The helper validates its input and only allows the two supported modes.
- No network requests, telemetry, or analytics are included.
- This app changes battery charge thresholds on your machine. Review the source
  and use it only on hardware where you understand the expected TLP behavior.

## Uninstall

```sh
sudo apt remove charge-controller
```

Uninstalling the package does not currently remove the managed block or backup
from `/etc/tlp.conf`; remove those manually if you want to fully revert the
configuration.

## Development

Useful validation commands:

```sh
desktop-file-validate data/charge-controller.desktop data/charge-controller-autostart.desktop
python3 -c "import xml.etree.ElementTree as ET; [ET.parse(p) for p in ['data/io.github.yousaf.ChargeController.policy','data/charge-controller.svg']]"
dpkg-source --before-build .
dpkg-buildpackage -us -uc -b
```

## License

MIT. See [LICENSE](LICENSE).
