#!/usr/bin/env bash
# Convenience wrapper. Canonical teardown logic lives in teardown.sh.
set -Eeuo pipefail
exec "$(dirname "$0")/teardown.sh" "$@"

