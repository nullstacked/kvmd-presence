#!/bin/bash
set -e

SHARE_DIR="/usr/share/kvmd-presence"
LOG_PREFIX="kvmd-presence"

log() { echo "[$LOG_PREFIX] $*"; }
warn() { echo "[$LOG_PREFIX] WARNING: $*" >&2; }

# Find kvmd install location
find_kvmd_dir() {
    python3 -c "import kvmd; import os; print(os.path.dirname(kvmd.__file__))" 2>/dev/null
}

KVMD_DIR="$(find_kvmd_dir)" || true
if [ -z "$KVMD_DIR" ] || [ ! -d "$KVMD_DIR" ]; then
    warn "Could not find kvmd Python package. Is kvmd installed?"
    exit 1
fi

log "Found kvmd at: $KVMD_DIR"

WEB_DIR="/usr/share/kvmd/web"

# Track success/failure
PATCHED=0
SKIPPED=0
FAILED=0

patch_ok()   { log "PATCHED: $1"; PATCHED=$((PATCHED + 1)); }
patch_skip() { log "SKIPPED (already applied): $1"; SKIPPED=$((SKIPPED + 1)); }
patch_fail() { warn "FAILED: $1"; FAILED=$((FAILED + 1)); }

# ============================================================
# Step 1: Copy presence.py module
# ============================================================
copy_presence_module() {
    local dest="$KVMD_DIR/apps/kvmd/presence.py"
    if [ -f "$dest" ] && cmp -s "$SHARE_DIR/presence.py" "$dest" 2>/dev/null; then
        patch_skip "presence.py module"
    else
        cp "$SHARE_DIR/presence.py" "$dest" && patch_ok "presence.py module" || patch_fail "presence.py module"
    fi
}

# ============================================================
# Step 2: Copy presence.css
# ============================================================
copy_presence_css() {
    local dest="$WEB_DIR/share/css/kvm/presence.css"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && cmp -s "$SHARE_DIR/presence.css" "$dest" 2>/dev/null; then
        patch_skip "presence.css"
    else
        cp "$SHARE_DIR/presence.css" "$dest" && patch_ok "presence.css" || patch_fail "presence.css"
    fi
}

# ============================================================
# Steps 3-9: Python-based patching (idempotent)
# ============================================================
run_python_patches() {
    python3 << 'PYEOF'
import sys
import os
import re

KVMD_DIR = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("KVMD_DIR", "")
WEB_DIR = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/kvmd/web"

# Re-read from env
KVMD_DIR = os.environ.get("KVMD_DIR", "")
WEB_DIR = "/usr/share/kvmd/web"

patched = 0
skipped = 0
failed = 0

def log(msg):
    print(f"[kvmd-presence] {msg}")

def patch_ok(name):
    global patched
    log(f"PATCHED: {name}")
    patched += 1

def patch_skip(name):
    global skipped
    log(f"SKIPPED (already applied): {name}")
    skipped += 1

def patch_fail(name, err=""):
    global failed
    log(f"FAILED: {name} {err}")
    failed += 1

def read_file(path):
    with open(path, "r") as f:
        return f.read()

def write_file(path, content):
    with open(path, "w") as f:
        f.write(content)

def ensure_import(content, import_line):
    """Add an import line after existing imports if not present."""
    if import_line in content:
        return content, False
    # Find last import block line
    lines = content.split("\n")
    last_import_idx = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("import ") or stripped.startswith("from "):
            last_import_idx = i
    lines.insert(last_import_idx + 1, import_line)
    return "\n".join(lines), True

# ============================================================
# Patch server.py
# ============================================================
def patch_server():
    path = os.path.join(KVMD_DIR, "apps", "kvmd", "server.py")
    if not os.path.exists(path):
        patch_fail("server.py (file not found)")
        return

    try:
        content = read_file(path)
        original = content
        changed = False

        # Add 'import asyncio' if missing
        if "import asyncio" not in content:
            content, did = ensure_import(content, "import asyncio")
            changed = changed or did

        # Add 'from . import presence' if missing
        if "from . import presence" not in content:
            content, did = ensure_import(content, "from . import presence")
            changed = changed or did

        # Add presence_enabled param to KvmdServer.__init__
        if "presence_enabled" not in content:
            # Find __init__ signature and add param
            # Look for the closing paren of __init__
            init_match = re.search(
                r'(class KvmdServer.*?def __init__\(self.*?)(,?\s*\) -> None:)',
                content, re.DOTALL
            )
            if init_match:
                content = content[:init_match.end(1)] + \
                    ",\n        presence_enabled: bool=False" + \
                    content[init_match.start(2):]
                changed = True

        # Add instance variables after __init__ body start
        if "__presence_enabled" not in content:
            # Find first self.__ assignment in __init__
            init_body = re.search(r'(def __init__\(self.*?\) -> None:\s*\n)', content, re.DOTALL)
            if init_body:
                insert_pos = init_body.end()
                # Find first self. line
                first_self = content.find("        self.", insert_pos)
                if first_self > 0:
                    presence_vars = (
                        "        self.__presence_enabled = presence_enabled\n"
                        "        self.__presence_loop_task: (asyncio.Task | None) = None\n"
                        "        self.__prev_presence_state: (dict | None) = None\n"
                    )
                    content = content[:first_self] + presence_vars + content[first_self:]
                    changed = True

        # Add presence hooks in _on_ws_added
        if "presence.set_user" not in content:
            ws_added = content.find("async def _on_ws_added(")
            if ws_added >= 0:
                # Find the end of the method (next method or end)
                # Insert before the end of the method body
                # Look for the return or last statement
                next_def = content.find("\n    async def ", ws_added + 1)
                if next_def < 0:
                    next_def = content.find("\n    def ", ws_added + 1)
                if next_def > 0:
                    insert_code = (
                        "\n        if self.__presence_enabled:\n"
                        "            presence.set_user(ws.token, ws.user)\n"
                        "            if self.__presence_loop_task is None:\n"
                        "                self.__presence_loop_task = asyncio.ensure_future(self.__presence_loop())\n"
                    )
                    content = content[:next_def] + insert_code + content[next_def:]
                    changed = True

        # Add presence hooks in _on_ws_removed
        if "presence.unset_user" not in content:
            ws_removed = content.find("async def _on_ws_removed(")
            if ws_removed >= 0:
                next_def = content.find("\n    async def ", ws_removed + 1)
                if next_def < 0:
                    next_def = content.find("\n    def ", ws_removed + 1)
                if next_def > 0:
                    insert_code = (
                        "\n        if self.__presence_enabled:\n"
                        "            presence.unset_user(ws.token)\n"
                    )
                    content = content[:next_def] + insert_code + content[next_def:]
                    changed = True

        # Add __broadcast_presence and __presence_loop methods
        if "__broadcast_presence" not in content:
            # Add before last line or at end of class
            # Find a good insertion point - before the last method or at end
            # We'll add before the class ends
            methods_code = '''
    async def __broadcast_presence(self) -> None:
        state = {
            "connected": presence.get_connected_users(),
            "controllers": presence.get_controllers(),
            "active": presence.get_active(),
        }
        if state != self.__prev_presence_state:
            self.__prev_presence_state = state
            await self._broadcast_ws_event("presence", state)

    async def __presence_loop(self) -> None:
        try:
            while True:
                await self.__broadcast_presence()
                await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            pass
        except Exception:
            from ...logging import get_logger
            get_logger(0).exception("Presence loop error")
'''
            # Insert before the last line of the file (or end of class)
            # Find the last method in the class
            last_def_pos = content.rfind("\n    async def ")
            if last_def_pos < 0:
                last_def_pos = content.rfind("\n    def ")
            if last_def_pos > 0:
                # Find end of that method
                next_class_or_end = len(content)
                # Look for next top-level def/class or EOF
                search_from = last_def_pos + 10
                for m in re.finditer(r'\n(?=\S)', content[search_from:]):
                    next_class_or_end = search_from + m.start()
                    break
                content = content[:next_class_or_end] + methods_code + content[next_class_or_end:]
                changed = True

        if changed:
            write_file(path, content)
            patch_ok("server.py")
        else:
            patch_skip("server.py")
    except Exception as e:
        patch_fail("server.py", str(e))

# ============================================================
# Patch hid.py
# ============================================================
def patch_hid():
    path = os.path.join(KVMD_DIR, "apps", "kvmd", "api", "hid.py")
    if not os.path.exists(path):
        patch_fail("hid.py (file not found)")
        return

    try:
        content = read_file(path)
        changed = False

        # Add 'from .. import presence' if missing
        if "from .. import presence" not in content:
            content, did = ensure_import(content, "from .. import presence")
            changed = changed or did

        # Change '_: WsSession' to 'ws: WsSession' in __ws_ handlers
        if "_: WsSession" in content:
            content = content.replace("_: WsSession", "ws: WsSession")
            changed = True

        # Add presence.record_input(ws.token) after specific HID send calls in ws handlers.
        # Use exact call signatures to avoid matching non-ws methods like __print_handler.
        if "presence.record_input" not in content:
            exact_calls = [
                "self.__hid.send_key_event(key, state, finish)",
                "self.__hid.send_mouse_button_event(button, state)",
                "self.__hid.send_mouse_move_event(to_x, to_y)",
                "self.__process_ws_delta_event(event, self.__hid.send_mouse_relative_events)",
                "self.__process_ws_delta_event(event, self.__hid.send_mouse_wheel_events)",
                "self.__process_ws_bin_delta_request(data, self.__hid.send_mouse_relative_events)",
                "self.__process_ws_bin_delta_request(data, self.__hid.send_mouse_wheel_events)",
            ]
            for call in exact_calls:
                target = call + "\n"
                replacement = call + "\n        presence.record_input(ws.token)\n"
                if target in content and replacement not in content:
                    content = content.replace(target, replacement)
                    changed = True

        if changed:
            write_file(path, content)
            patch_ok("hid.py")
        else:
            patch_skip("hid.py")
    except Exception as e:
        patch_fail("hid.py", str(e))

# ============================================================
# Patch _scheme.py
# ============================================================
def patch_scheme():
    path = os.path.join(KVMD_DIR, "apps", "_scheme.py")
    if not os.path.exists(path):
        # Try alternate location
        path = os.path.join(KVMD_DIR, "apps", "kvmd", "_scheme.py")
    if not os.path.exists(path):
        # Search for it
        for root, dirs, files in os.walk(os.path.join(KVMD_DIR, "apps")):
            if "_scheme.py" in files:
                path = os.path.join(root, "_scheme.py")
                break
    if not os.path.exists(path):
        patch_fail("_scheme.py (file not found)")
        return

    try:
        content = read_file(path)
        if '"presence"' in content:
            patch_skip("_scheme.py")
            return

        # Find a good place to insert - look for pattern near kvmd config
        # Insert the presence option block
        # Look for a suitable dict entry to insert after
        # Try to find the end of the kvmd scheme options
        insertion = '            "presence": {"enabled": Option(False, type=valid_bool)},\n'

        # Look for a pattern like "hid": { or similar top-level kvmd key
        # Insert before the closing of the kvmd dict
        # Simple approach: find last Option(...) line in the kvmd section and insert after
        if "valid_bool" not in content:
            # Need to check if valid_bool is imported
            if "from ..validators.basic import" in content:
                if "valid_bool" not in content:
                    content = content.replace(
                        "from ..validators.basic import",
                        "from ..validators.basic import valid_bool,",
                        1
                    )

        # Find a good insertion point - after the last top-level key in the kvmd scheme
        # Look for patterns like '"gpio":' or '"info":' at the right indent level
        lines = content.split("\n")
        insert_idx = None
        brace_depth = 0
        in_kvmd = False
        for i, line in enumerate(lines):
            if '"kvmd"' in line or "'kvmd'" in line:
                in_kvmd = True
            if in_kvmd:
                # Find a line that has a top-level key in the kvmd dict
                stripped = line.strip()
                if stripped.startswith('"') and stripped.endswith('{'):
                    insert_idx = i  # Keep updating to find last one

        if insert_idx is not None:
            lines.insert(insert_idx, insertion.rstrip())
            content = "\n".join(lines)
        else:
            # Fallback: insert before last closing brace area
            # Just append after the last "Option(" line
            last_option = content.rfind("Option(")
            if last_option > 0:
                eol = content.find("\n", last_option)
                if eol > 0:
                    content = content[:eol+1] + insertion + content[eol+1:]

        write_file(path, content)
        patch_ok("_scheme.py")
    except Exception as e:
        patch_fail("_scheme.py", str(e))

# ============================================================
# Patch kvmd/__init__.py
# ============================================================
def patch_kvmd_init():
    path = os.path.join(KVMD_DIR, "apps", "kvmd", "__init__.py")
    if not os.path.exists(path):
        patch_fail("kvmd/__init__.py (file not found)")
        return

    try:
        content = read_file(path)
        if "presence_enabled" in content:
            patch_skip("kvmd/__init__.py")
            return

        # Find KvmdServer( constructor call and add presence_enabled param
        if "KvmdServer(" in content:
            # Find the closing paren of the KvmdServer(...) call
            idx = content.find("KvmdServer(")
            if idx >= 0:
                # Find the matching closing paren
                paren_depth = 0
                end_idx = idx
                for j in range(idx, len(content)):
                    if content[j] == '(':
                        paren_depth += 1
                    elif content[j] == ')':
                        paren_depth -= 1
                        if paren_depth == 0:
                            end_idx = j
                            break
                # Insert before closing paren
                insert = "\n            presence_enabled=config.presence.enabled,\n        "
                # Check if there's already a trailing comma
                before_paren = content[end_idx-1]
                if before_paren == ',':
                    insert = "\n            presence_enabled=config.presence.enabled,\n        "
                content = content[:end_idx] + insert + content[end_idx:]
                write_file(path, content)
                patch_ok("kvmd/__init__.py")
                return

        patch_fail("kvmd/__init__.py (could not find KvmdServer call)")
    except Exception as e:
        patch_fail("kvmd/__init__.py", str(e))

# ============================================================
# Patch index.html
# ============================================================
def patch_index_html():
    path = os.path.join(WEB_DIR, "kvm", "index.html")
    if not os.path.exists(path):
        patch_fail("index.html (file not found)")
        return

    try:
        content = read_file(path)
        changed = False

        # Add CSS link if missing
        if "presence.css" not in content:
            # Insert after last CSS link
            last_css = content.rfind('<link rel="stylesheet"')
            if last_css >= 0:
                eol = content.find("\n", last_css)
                if eol >= 0:
                    css_link = '\n\t\t<link rel="stylesheet" href="../share/css/kvm/presence.css">'
                    content = content[:eol] + css_link + content[eol:]
                    changed = True

        # Add presence toggle checkbox row if missing
        if "presence-overlay-switch" not in content:
            # Find a suitable place in the settings/controls area
            # Look for another switch row and add after it
            # Try to find the about section or settings area
            target = 'id="stream-audio-switch"'
            if target not in content:
                target = 'id="hid-keyboard-switch"'
            if target not in content:
                target = 'class="feature-checkbox"'

            if target in content:
                idx = content.find(target)
                # Find the end of this row (closing tr or div)
                eol = content.find("\n", idx)
                # Find the closing tag of this row
                row_end = content.find("</tr>", idx)
                if row_end < 0:
                    row_end = content.find("</div>", idx)
                if row_end > 0:
                    row_end = content.find("\n", row_end)
                    toggle_html = (
                        '\n\t\t\t\t\t\t<tr>'
                        '\n\t\t\t\t\t\t\t<td>Presence overlay:</td>'
                        '\n\t\t\t\t\t\t\t<td><input type="checkbox" id="presence-overlay-switch" checked /></td>'
                        '\n\t\t\t\t\t\t</tr>'
                    )
                    content = content[:row_end] + toggle_html + content[row_end:]
                    changed = True

        # Add presence overlay div if missing
        if "presence-overlay" not in content or 'id="presence-overlay"' not in content:
            # Add div after stream container or body
            stream_div = content.find('id="stream-box"')
            if stream_div < 0:
                stream_div = content.find('id="stream"')
            if stream_div >= 0:
                # Find the opening tag end
                tag_end = content.find(">", stream_div)
                if tag_end > 0:
                    overlay_div = '\n\t\t\t<div id="presence-overlay" class="presence-overlay"></div>'
                    content = content[:tag_end+1] + overlay_div + content[tag_end+1:]
                    changed = True

        if changed:
            write_file(path, content)
            patch_ok("index.html")
        else:
            patch_skip("index.html")
    except Exception as e:
        patch_fail("index.html", str(e))

# ============================================================
# Patch session.js
# ============================================================
def patch_session_js():
    path = os.path.join(WEB_DIR, "share", "js", "kvm", "session.js")
    if not os.path.exists(path):
        patch_fail("session.js (file not found)")
        return

    try:
        content = read_file(path)
        changed = False

        # Add __updatePresenceOverlay function if missing
        if "__updatePresenceOverlay" not in content:
            # Insert before __wsJsonHandler
            target = "__wsJsonHandler"
            idx = content.find(target)
            if idx > 0:
                # Find the function/method start
                # Go back to find the function definition line
                line_start = content.rfind("\n", 0, idx)
                func_code = '''
\t__updatePresenceOverlay(data) {
\t\tlet el = document.getElementById("presence-overlay");
\t\tif (!el) return;
\t\tlet show = tools.storage.getBool("presence.overlay", true);
\t\tif (!show || !data) { el.innerHTML = ""; return; }
\t\tlet html = "";
\t\tfor (let user of (data.connected || [])) {
\t\t\tlet cls = "presence-user-idle";
\t\t\tif ((data.controllers || []).indexOf(user) >= 0) {
\t\t\t\tcls = "presence-user-controlling";
\t\t\t}
\t\t\thtml += "<div class=\\"" + cls + "\\">" + user + "</div>";
\t\t}
\t\tel.innerHTML = html;
\t}

'''
                content = content[:line_start] + "\n" + func_code + content[line_start:]
                changed = True

        # Add case "presence" in switch if missing
        if '"presence"' not in content:
            # Find the switch statement in wsJsonHandler
            switch_idx = content.find("switch (", content.find("__wsJsonHandler"))
            if switch_idx > 0:
                # Find a case statement to insert before/after
                # Find the default: case or last case
                default_idx = content.find("default:", switch_idx)
                if default_idx < 0:
                    # Find last case
                    last_case = content.rfind("case ", switch_idx)
                    default_idx = last_case
                if default_idx > 0:
                    presence_case = '\t\t\t\tcase "presence": this.__updatePresenceOverlay(data); break;\n'
                    content = content[:default_idx] + presence_case + content[default_idx:]
                    changed = True

        # Add bindSimpleSwitch for presence toggle if missing
        if '"presence.overlay"' not in content:
            # Find where other bindSimpleSwitch calls are made
            bind_idx = content.rfind("tools.feature.bindSimpleSwitch(")
            if bind_idx < 0:
                bind_idx = content.rfind("bindSimpleSwitch(")
            if bind_idx > 0:
                eol = content.find("\n", bind_idx)
                if eol > 0:
                    bind_code = '\n\t\ttools.feature.bindSimpleSwitch($("presence-overlay-switch"), "presence.overlay", true);'
                    content = content[:eol] + bind_code + content[eol:]
                    changed = True

        if changed:
            write_file(path, content)
            patch_ok("session.js")
        else:
            patch_skip("session.js")
    except Exception as e:
        patch_fail("session.js", str(e))

# ============================================================
# Run all patches
# ============================================================
patch_server()
patch_hid()
patch_scheme()
patch_kvmd_init()
patch_index_html()
patch_session_js()

# Print summary
total = patched + skipped + failed
log(f"Python patches complete: {patched} patched, {skipped} skipped, {failed} failed (of {total})")
if failed > 0:
    sys.exit(1)
PYEOF
}

# ============================================================
# Main
# ============================================================
export KVMD_DIR

copy_presence_module
copy_presence_css
run_python_patches

# Clear __pycache__
log "Clearing __pycache__ directories..."
find "$KVMD_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Restart kvmd if running
if systemctl is-active --quiet kvmd 2>/dev/null; then
    log "Restarting kvmd..."
    systemctl restart kvmd
    log "kvmd restarted."
else
    log "kvmd is not running, skipping restart."
fi

log "Done. Patched=$PATCHED, Skipped=$SKIPPED, Failed=$FAILED"
