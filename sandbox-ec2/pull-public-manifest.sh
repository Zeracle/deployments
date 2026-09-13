#!/usr/bin/env bash
# After an EC2 sandbox redeploy: copy the box's public manifest into this repo
# (it is TRACKED — commit it via a PR), validating it with chain-view first.
set -euo pipefail
: "${EC2_SSH:?EC2_SSH must be the ssh destination of the sandbox box, e.g. ec2-user@<host>}"
HERE=$(cd "$(dirname "$0")" && pwd)
scp "$EC2_SSH:/data/public-manifest.json" "$HERE/public-manifest.json"
npm --prefix "$HERE/../../chain-view" run -s validate-manifest -- "$HERE/public-manifest.json"
