# kvmd-presence

User presence overlay for [PiKVM](https://pikvm.org/) — shows who is watching and who is controlling the KVM in real-time.

![PiKVM Presence Overlay](https://img.shields.io/badge/PiKVM-Extension-blue)

## What it does

When multiple users connect to the same PiKVM, this extension adds a small text overlay on the video stream showing:

- **"is controlling"** (green) — user has active keyboard/mouse input in the last 10 seconds
- **"is watching"** — user is connected and recently active
- **"is watching (idle)"** (dimmed) — user is connected but no input for 5+ minutes

The overlay is toggleable per-browser via Web UI settings.

## Requirements

- PiKVM with kvmd 4.140+
- Authentication enabled (`kvmd.auth.enabled: true` in override.yaml)

## Installation

Download the latest release and install:

```bash
curl -LO https://github.com/nullstacked/kvmd-presence/releases/latest/download/kvmd-presence-1.0.0-1-any.pkg.tar.zst
pacman -U kvmd-presence-1.0.0-1-any.pkg.tar.zst
```

Then enable in `/etc/kvmd/override.yaml`:

```yaml
kvmd:
    presence:
        enabled: true
```

Restart kvmd:

```bash
systemctl restart kvmd
```

## Survives kvmd updates

An ALPM hook automatically re-applies patches after any `kvmd` package upgrade. If a kvmd update changes internal APIs and patches can't apply, the hook logs a warning — kvmd still works normally, just without presence until the package is updated.

## Uninstall

```bash
pacman -R kvmd-presence
pacman -S kvmd  # reinstall to restore original files
systemctl restart kvmd
```

## Customization

All styling uses CSS custom properties. Override in `/etc/kvmd/web.css`:

```css
:root {
    --cs-presence-fg: #fff;
    --cs-presence-controlling-fg: #4caf50;
    --cs-presence-idle-opacity: 0.5;
    --cs-presence-font-size: 12px;
    --cs-presence-top: 6px;
    --cs-presence-left: 6px;
    --cs-presence-shadow: 1px 1px 2px rgba(0,0,0,0.8), -1px -1px 2px rgba(0,0,0,0.8);
}
```

## Performance

Zero measurable impact:

- HID hot path adds ~200ns per event (rate-limited to 4 calls/sec per user)
- Memory: ~500 bytes total (3 small dicts bounded by user count)
- WS bandwidth: diff-only broadcasts, ~100 bytes per state change
- When disabled: zero overhead

## Building from source

On a PiKVM device:

```bash
git clone https://github.com/nullstacked/kvmd-presence
cd kvmd-presence
makepkg -f
pacman -U kvmd-presence-*.pkg.tar.zst
```

## License

GPL-3.0 — same as kvmd.
