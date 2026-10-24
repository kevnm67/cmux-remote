#!/usr/bin/env bash
# Install the always-on relay scripts into ~/.cmuxremote/bin (leaves cmux-relay
# and relay.json untouched) and print the ~/.zshrc line that triggers them.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${CMUX_RELAY_HOME:-$HOME/.cmuxremote}/bin"
mkdir -p "$dest"
for f in relay-common.sh run-relay-in-cmux.sh ensure-relay.sh relay-watchdog.sh relay-probe.py; do
    install -m 0755 "$here/$f" "$dest/$f"
done
echo "installed to $dest"
if ! grep -qF 'ensure-relay.sh' "$HOME/.zshrc" 2>/dev/null; then
    cat <<LINE
add to ~/.zshrc:
if [[ -n "\${CMUX_WORKSPACE_ID:-}" && -x "$dest/ensure-relay.sh" ]]; then
  "$dest/ensure-relay.sh" >/dev/null 2>&1 &!
fi
LINE
fi
