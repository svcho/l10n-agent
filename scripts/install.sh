#!/usr/bin/env bash
# Builds a release binary and installs it (default: ~/.local/bin).
set -euo pipefail
cd "$(dirname "$0")/.."

prefix="${1:-$HOME/.local/bin}"
swift build -c release --product l10n-agent
mkdir -p "$prefix"
install -m 0755 "$(swift build -c release --show-bin-path)/l10n-agent" "$prefix/l10n-agent"
echo "Installed l10n-agent to $prefix/l10n-agent"
case ":$PATH:" in
  *":$prefix:"*) ;;
  *) echo "Add $prefix to your PATH to run l10n-agent from anywhere." ;;
esac
