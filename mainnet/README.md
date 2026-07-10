# mainnet deployment

Deployment configuration for Aztec mainnet (not the sandbox). Requires the
testnet migration to be complete. Belongs here when the migration starts:
deploy configuration, the mainnet `deployment-manifest.json`, runbooks.
Nothing sandbox-shaped may be copied in — see
docs/versions/260709/existing-limitations.md for the capability gaps that
must be addressed first (block timing, fee sponsorship, account directory
removal).

`deploy-mainnet.sh` is a fail-loud stub until that migration lands — it exits
1 and points at the prerequisites above.
