# ===========================================================================
# Zeracle — task runner
#
# Lives in deployments/ (moved from the repo root). Thin wrappers around the
# per-environment scripts in ./sandbox-local, ./sandbox-ec2, ./testnet, and
# ./mainnet. Run from anywhere with `make -C deployments` or
# `make -C deployments help` to list available targets.
#
# Terminology: sandbox != testnet. sandbox-local and sandbox-ec2 are both
# the Aztec SANDBOX (local, single-node); "testnet" only ever means the
# official Aztec testnet.
# ===========================================================================

.DEFAULT_GOAL := help

CHAIN_SERVER_DIR := ../chain-server
WEB_DIR := ../interfaces/apps/web

.PHONY: help test \
        deploy-sandbox-local deploy-sandbox-local-skip-infra stop-sandbox-local stop-clean \
        stop check-local-sandbox-allowed \
        deploy-sandbox-ec2 deploy-sandbox-ec2-apply \
        sync-pi provision-pi deploy-pi e2e-pi web-env-pi build-web-pi deploy-web-pi \
        deploy-testnet deploy-mainnet \
        chain-server chain-server-dev \
        fes fes-web fes-docs fes-chain stop-fes stop-fes-web stop-fes-docs stop-fes-chain

## ----- Sandbox: local (this machine) — RETIRED -----
#
# Retired 2026-09-24: all testing runs on the Pi chain host (deploy-pi below).
# A laptop deploy writes interfaces/apps/web/.env.local, which Vite loads in
# every mode — including the Pi build — so it is refused unless explicitly
# asked for. The script itself stays: deploy-pi.sh runs it headless on the Pi.

check-local-sandbox-allowed:
	@test "$(ALLOW_LOCAL_SANDBOX)" = 1 || { \
		echo "The laptop sandbox is retired: all testing runs on the Pi."; \
		echo "  Pi chain:   make -C deployments deploy-pi"; \
		echo "  Web env:    make -C deployments web-env-pi"; \
		echo "Set ALLOW_LOCAL_SANDBOX=1 to run it anyway (writes interfaces/apps/web/.env.local)."; \
		exit 1; }

deploy-sandbox-local: check-local-sandbox-allowed ## RETIRED — local sandbox deploy; needs ALLOW_LOCAL_SANDBOX=1
	./sandbox-local/deploy-sandbox.sh

deploy-sandbox-local-skip-infra: check-local-sandbox-allowed ## RETIRED — as above, skipping Anvil/Sandbox start
	./sandbox-local/deploy-sandbox.sh --skip-infra

stop-sandbox-local: ## Stop the local sandbox stack (keep logs)
	./sandbox-local/stop-sandbox.sh

stop: stop-sandbox-local ## Alias for stop-sandbox-local

stop-clean: ## Stop the local sandbox stack and delete /tmp/zeracle-*.log
	./sandbox-local/stop-sandbox.sh --clean-logs

## ----- Sandbox: EC2 (hosted, persistent) -----

deploy-sandbox-ec2: ## Build the EC2 sandbox release tarball, print next steps
	./sandbox-ec2/deploy-ec2.sh

deploy-sandbox-ec2-apply: ## Build the tarball, then `terraform apply` (interactive)
	./sandbox-ec2/deploy-ec2.sh --apply

## ----- Sandbox: Raspberry Pi chain host (hosted, persistent) -----
#
# Replaced the retired EC2 box. Chain services + build host on the Pi; see
# pi/README.md. sync-pi ships the same release tarball EC2 uses, so the two
# platform layers cannot drift.

sync-pi: ## Push the zeracle tree to the Pi at /opt/zeracle (release tarball)
	./pi/sync-to-pi.sh

provision-pi: ## One-time idempotent host setup on the Pi (swap, docker, node, foundry, solc, units)
	ssh $${PI_HOST:-pi} 'bash /opt/zeracle/deployments/pi/provision-pi.sh'

deploy-pi: ## Deploy (or resume) the chain on the Pi
	ssh $${PI_HOST:-pi} 'bash /opt/zeracle/deployments/pi/deploy-pi.sh'

# ZER-17. Brings the chain up if needed, checks it matches its manifest,
# collateralises the portal if needed, then runs v1-l2 fees.flush-claim with
# ZERACLE_E2E_REQUIRE_SANDBOX=1 — on the Pi, because the sandbox tools refuse
# non-localhost endpoints. Runs the code already on the box: sync-pi first to
# test a branch.
e2e-pi: ## Run the real-Outbox fee round-trip e2e on the Pi (see pi/e2e-pi.sh)
	ssh -o ServerAliveInterval=30 $${PI_HOST:-pi} 'bash /opt/zeracle/deployments/pi/e2e-pi.sh'

web-env-pi: ## Regenerate interfaces/apps/web/.env.pi from the Pi deployment manifest
	./pi/gen-web-env.sh

build-web-pi: ## Build the web app against the Pi chain host
	$(MAKE) -C $(WEB_DIR) build-pi

# Delegates to the web app's own Makefile, which already owns the two-pass S3
# sync (hashed assets immutable; index.html/sw.js/webmanifest no-cache — the
# PWA service worker must never be cached immutably) and the CloudFront
# invalidation, with the bucket and distribution defaulted there.
deploy-web-pi: ## Build + publish the web app to S3/CloudFront (see interfaces/apps/web/Makefile)
	$(MAKE) -C $(WEB_DIR) deploy-pi

## ----- Testnet (official Aztec testnet — not the sandbox) -----

deploy-testnet: ## Not yet configured — fails loud with migration prerequisites
	./testnet/deploy-testnet.sh

## ----- Mainnet -----

deploy-mainnet: ## Not yet configured — fails loud with migration prerequisites
	./mainnet/deploy-mainnet.sh

## ----- Chain server (run manually in its own terminal) -----

chain-server: ## Start the chain server (tsx src/index.ts)
	cd $(CHAIN_SERVER_DIR) && npm start

chain-server-dev: ## Start the chain server in watch mode
	cd $(CHAIN_SERVER_DIR) && npm run dev

## ----- Frontends -----

fes: ## Start all frontends (web + docs + chain)
	./sandbox-local/start-fes.sh

fes-web: ## Start only the web app (:5173)
	./sandbox-local/start-fes.sh web

fes-docs: ## Start only the docs app (:3000)
	./sandbox-local/start-fes.sh docs

fes-chain: ## Start only the chain view (:5174)
	./sandbox-local/start-fes.sh chain

stop-fes: ## Stop all frontends
	./sandbox-local/stop-fes.sh

stop-fes-web: ## Stop only the web app
	./sandbox-local/stop-fes.sh web

stop-fes-docs: ## Stop only the docs app
	./sandbox-local/stop-fes.sh docs

stop-fes-chain: ## Stop only the chain view
	./sandbox-local/stop-fes.sh chain

## ----- Tests -----

# ZER-11: these shell tests existed with nothing to run them, so a regression
# guard only spoke up if someone happened to invoke it by hand — which is not
# the moment a guard is for. They are all offline: they read and parse scripts
# rather than executing them, and never touch Sepolia, the Aztec testnet or the
# EC2 sandbox. Two exceptions worth knowing: install-mock-feeds-chain-guard
# binds local port 8597 for a stub RPC, and deploy-testnet-force-version
# (ZER-71) runs deploy-testnet.sh --preflight-only in a temp dir against a
# stub Aztec node on an OS-assigned 127.0.0.1 port (still no outside network).
test: ## Run the offline shell tests (lib/test + sandbox-local/test + pi/test)
	@fail=0; \
	for t in lib/test/*.test.sh sandbox-local/test/*.test.sh pi/test/*.test.sh; do \
	  [ -f "$$t" ] || continue; \
	  echo "== $$t"; \
	  bash "$$t" || fail=1; \
	done; \
	exit $$fail

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
