# AGENTS.md

## Project

Charge Controller is a native Ubuntu 24.04 desktop tray app for ThinkPad battery charge thresholds.

- UI binary: `charge-controller`
- Privileged helper: `charge-controller-helper`
- Language/tooling: Vala, GTK 3, Ayatana AppIndicator, Meson, Debian packaging
- Battery target: `BAT0`
- Backend: TLP through `/usr/sbin/tlp`

## Build And Package

Install build dependencies:

```sh
sudo apt install build-essential debhelper meson ninja-build valac pkg-config libgtk-3-dev libayatana-appindicator3-dev
```

Build the Debian package from the repo root:

```sh
dpkg-buildpackage -us -uc -b
```

The `.deb` is emitted one directory above the repo root, for example:

```text
/home/yousaf/charge-controller_0.1.0_amd64.deb
```

## Validation

Useful checks:

```sh
desktop-file-validate data/charge-controller.desktop data/charge-controller-autostart.desktop
python3 -c "import xml.etree.ElementTree as ET; [ET.parse(p) for p in ['data/io.github.yousaf.ChargeController.policy','data/charge-controller.svg']]"
dpkg-source --before-build .
dpkg-buildpackage -us -uc -b
```

## Release Workflow

- Release workflow: `.github/workflows/release.yml`.
- Trigger: push a tag, usually `v<debian-changelog-version>`, or run manually with `workflow_dispatch`.
- The workflow verifies that the tag commit is reachable from `origin/main`.
- The workflow verifies that the tag matches the current Debian changelog version, with or without a leading `v`.
- The workflow builds on `ubuntu-24.04` and attaches `dist/*.deb` to the matching GitHub release.
- Manual runs without `create_release` only build and upload a workflow artifact.

## Safety Notes

- Do not rewrite this as Python; the intended app is a native packaged Vala utility.
- Do not run the helper, `pkexec`, or TLP-changing commands unless the user explicitly asks to apply charge settings.
- The helper must only accept the two supported modes: `limit-80` and `charge-100`.
- The helper owns only the marked `# BEGIN charge-controller` / `# END charge-controller` block in `/etc/tlp.conf`.
- Keep generated Meson/Debhelper artifacts out of source control; `.gitignore` covers `obj-*`, `debian/.debhelper`, package outputs, and generated C.
