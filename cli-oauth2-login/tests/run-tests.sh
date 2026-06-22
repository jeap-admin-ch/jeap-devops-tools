#!/usr/bin/env bash
# Runs the bats test suite for oidc-discovery-override.sh. Requires bats-core
# (https://bats-core.readthedocs.io):
#   Linux:  apt install bats      macOS:  brew install bats-core
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found — install it via 'apt install bats' or 'brew install bats-core'" >&2
  exit 1
fi
exec bats .
