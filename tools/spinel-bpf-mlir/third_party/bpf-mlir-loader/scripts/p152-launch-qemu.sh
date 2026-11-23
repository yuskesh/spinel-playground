#!/usr/bin/env bash
set -euo pipefail
exec "${E064_HELPER:?}" launch-qemu "$@"
