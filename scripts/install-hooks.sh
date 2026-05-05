#!/usr/bin/env bash
# One-time setup: point this clone at the tracked hooks/ directory.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath hooks
chmod +x hooks/*
echo "core.hooksPath set to hooks/"
