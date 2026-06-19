#!/usr/bin/env bash
#
# build.sh — compile Notifier.swift, assemble the .app bundle, attach the
# icon, and ad-hoc sign it. The source of truth lives in this directory; the
# built .app is a runtime artifact (not version-controlled), placed in
# ~/.claude/tools (override with CLAUDE_TOOLS_DIR).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="Notifier"
dest="${CLAUDE_TOOLS_DIR:-$HOME/.claude/tools}/$name.app"
contents="$dest/Contents"
work="$(mktemp -d)"

trap 'rm -rf "$work"' EXIT

rm -rf "$dest"
mkdir -p "$contents/MacOS" "$contents/Resources"

# 1. Compile the executable straight into the bundle.
swiftc -O -o "$contents/MacOS/$name" "$here/Notifier.swift"

# 2. Bundle metadata.
cp "$here/Info.plist" "$contents/Info.plist"

# 3. Icon: build AppIcon.icns from icon.png (a 1024x1024 master).
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$here/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$here/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"

# 4. Ad-hoc sign — no Developer account; stable bundle id keeps the notification grant.
codesign --force --sign - "$dest"

# 5. Report where the finished bundle landed.
echo "built + signed: $dest"
