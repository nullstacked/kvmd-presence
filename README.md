# kvmd-presence

User presence overlay for [PiKVM](https://pikvm.org/) — shows who is watching and who is controlling the KVM in real-time.

![PiKVM Presence Overlay](https://img.shields.io/badge/PiKVM-Extension-blue)

## What it does

When multiple users connect to the same PiKVM, this extension adds a small text overlay on the video stream showing:

- **"is controlling"** (green) — user has active keyboard/mouse input in the last 10 seconds
- **"is watching"** — user is connected and recently active
- **"is watching (idle)"** (dimmed) — user is connected but no input for 5+ minutes

The overlay is toggleable per-browser via Web UI settings ("Show who is watching/controlling").

Works in both normal and full-screen/full-tab modes. No background — clean floating text with shadow for readability on any video content.

## Compatibility

| kvmd version | Status |
|---|---|
| 4.140 – 4.163 | Tested and working |
| < 4.140 | Untested — may work |
| > 4.163 | Should work unless upstream refactors internal APIs. ALPM hook will warn if patches fail. |

The patcher uses exact string matching on known kvmd code patterns. If a future kvmd update changes the internal structure, the ALPM hook will log a warning and skip the affected patch — kvmd continues working normally, just without presence until the package is updated.

## Requirements

- PiKVM with kvmd 4.140+
- Authentication enabled (`kvmd.auth.enabled: true` in override.yaml)
- Users must be logged in for presence to track them

## Installation

Download the latest release and install on your PiKVM:

```bash
rw
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
ro
```

## What gets patched

The package patches the following kvmd files (all changes are idempotent and revertible):

| File | Change |
|---|---|
| `kvmd/apps/kvmd/presence.py` | NEW — presence registry module |
| `kvmd/apps/kvmd/server.py` | WS lifecycle hooks + broadcast loop |
| `kvmd/apps/kvmd/api/hid.py` | Records input events per user |
| `kvmd/apps/_scheme.py` | Config schema for `presence.enabled` |
| `kvmd/apps/kvmd/__init__.py` | Passes config to server |
| `web/share/css/kvm/presence.css` | NEW — overlay styles |
| `web/share/js/kvm/session.js` | Overlay renderer + toggle binding |
| `web/kvm/index.html` | CSS link + settings toggle |

## Survives kvmd updates

An ALPM hook (`/etc/pacman.d/hooks/kvmd-presence.hook`) automatically re-applies patches after any `kvmd` package upgrade. If a kvmd update changes internal APIs and patches can't apply, the hook logs a warning — kvmd still works normally, just without presence until this package is updated.

## Uninstall

```bash
rw
pacman -R kvmd-presence
pacman -S kvmd  # reinstall to restore original files
systemctl restart kvmd
ro
```

## Customization

All styling uses CSS custom properties. Override in `/etc/kvmd/web.css` or your own stylesheet:

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

- **FPS:** HID hot path adds ~200ns per event (rate-limited to 4 calls/sec per user). Invisible against the video encode/decode pipeline.
- **Memory:** ~500 bytes total (3 small dicts bounded by user count). Auto-pruned after 1 hour.
- **WS bandwidth:** diff-only broadcasts, ~100 bytes per state change, at most a few per minute.
- **When disabled (default):** zero overhead — all presence code is gated behind `if self.__presence_enabled`.

## Building from source

On a PiKVM device (as non-root user):

```bash
git clone https://github.com/nullstacked/kvmd-presence
cd kvmd-presence
makepkg -f
rw
pacman -U kvmd-presence-*.pkg.tar.zst
ro
```

Or build on any Arch machine (package is `arch=any`) and copy the `.pkg.tar.zst` to your PiKVM.

## Related

- [PR #211 on pikvm/kvmd](https://github.com/pikvm/kvmd/pull/211) — upstream PR for native integration
- [kvmd-web-defaults](https://github.com/nullstacked/kvmd-web-defaults) — server-side UI defaults for PiKVM

## License

GPL-3.0 — same as kvmd.
