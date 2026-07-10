#!/bin/bash
# ===========================================================================
# Zeracle Mainnet Deploy — NOT YET CONFIGURED
#
# Requires the testnet migration (see ../testnet/) to be complete first.
# ===========================================================================

set -euo pipefail

echo "Zeracle mainnet deployment is not configured yet." >&2
echo "interfaces/apps/web/.env.mainnet is an unfilled skeleton — no real values." >&2
echo "See docs/versions/260709/existing-limitations.md (repo root) for the" >&2
echo "migration prerequisites (block timing, fee sponsorship, account" >&2
echo "directory removal) that must be addressed before this script can deploy." >&2
exit 1
