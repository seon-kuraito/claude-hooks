#!/usr/bin/env bash
#
# link-hook.sh — symlink a hook from this repo into ~/.claude/hooks so it can
# be registered in settings.json via a stable ~/.claude path while living here.
#
# Usage: scripts/link-hook.sh <hook-name>
#
# Idempotent: re-running is safe. Refuses to overwrite anything it doesn't own
# (e.g. a third-party hook of the same name).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_hooks="$(cd "$script_dir/.." && pwd)/hooks"
runtime_hooks="$HOME/.claude/hooks"

name="${1:-}"
if [ -z "$name" ]; then
  echo "usage: link-hook.sh <hook-name>" >&2
  exit 1
fi

src="$repo_hooks/$name"
dest="$runtime_hooks/$name"

if [ ! -d "$src" ]; then
  echo "error: hook not found in repo: $src" >&2
  exit 1
fi

# Already linked to the right place → nothing to do.
if [ -L "$dest" ]; then
  if [ "$(readlink "$dest")" = "$src" ]; then
    echo "ok: already linked — $name"
    exit 0
  fi
  echo "error: $dest already links elsewhere ($(readlink "$dest"))" >&2
  exit 1
fi

# A real file/dir is in the way → refuse to clobber it.
if [ -e "$dest" ]; then
  echo "error: $dest exists and is not a symlink — refusing to overwrite" >&2
  exit 1
fi

mkdir -p "$runtime_hooks"
ln -s "$src" "$dest"
echo "linked: $dest -> $src"
