#!/usr/bin/env bash
# Installs the ravn CLI (one bash script) into ~/.local/bin, then runs `ravn doctor`.
# Read it first: https://github.com/Raiyzs/ravn/blob/main/install.sh
set -euo pipefail

dest="${RAVN_BIN:-$HOME/.local/bin}"
ref="${RAVN_REF:-main}"
url="https://raw.githubusercontent.com/Raiyzs/ravn/$ref/ravn"

mkdir -p "$dest"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp"
bash -n "$tmp"                     # refuse a truncated or broken download
install -m 755 "$tmp" "$dest/ravn"
echo "ravn installed to $dest/ravn"

case ":$PATH:" in
  *":$dest:"*) ;;
  *) echo "note: $dest is not on your PATH — add it, or run $dest/ravn directly" ;;
esac

"$dest/ravn" doctor || true
