# sandbox-ec2 deployment

`deploy-ec2.sh` is the env-specific entry point for the EC2-hosted Aztec
SANDBOX (a persistent, shared chain, as opposed to `sandbox-local/`'s
ephemeral per-developer stack). It is a thin wrapper — the real provisioning
and bootstrap flow lives in `devops/production/ec2` (Terraform + tarball
build + `bootstrap.sh` + systemd units); this script does not duplicate that
logic, it drives it.

Usage:

```bash
./deploy-ec2.sh          # Build the release tarball, print next steps
./deploy-ec2.sh --apply  # Build the tarball, then `terraform apply` (interactive)
```

Or via the Makefile from `deployments/`: `make deploy-sandbox-ec2` /
`make deploy-sandbox-ec2-apply`.

Full runbook, variable reference, and recovery procedures:
`devops/production/ec2/README.md`.

Terminology: this is a **sandbox**, not "testnet" — "testnet" only ever means
the official Aztec testnet (see `../testnet/`).
