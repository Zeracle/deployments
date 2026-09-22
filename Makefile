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
        deploy deploy-skip-infra stop \
        deploy-sandbox-ec2 deploy-sandbox-ec2-apply \
        sync-pi provision-pi deploy-pi web-env-pi build-web-pi deploy-web-pi \
        deploy-testnet deploy-mainnet \
        chain-server chain-server-dev \
        fes fes-web fes-docs fes-chain stop-fes stop-fes-web stop-fes-docs stop-fes-chain

## ----- Sandbox: local (this machine) -----

deploy-sandbox-local: ## Full local sandbox deploy (starts Anvil + Sandbox)
	./sandbox-local/deploy-sandbox.sh

deploy: deploy-sandbox-local ## Alias for deploy-sandbox-local

deploy-sandbox-local-skip-infra: ## Local sandbox deploy, skipping Anvil/Sandbox (already running)
	./sandbox-local/deploy-sandbox.sh --skip-infra

deploy-skip-infra: deploy-sandbox-local-skip-infra ## Alias for deploy-sandbox-local-skip-infra

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

web-env-pi: ## Regenerate interfaces/apps/web/.env.pi from the Pi deployment manifest
	./pi/gen-web-env.sh

build-web-pi: ## Build the web app against the Pi chain host
	cd $(WEB_DIR) && yarn build:pi

deploy-web-pi: ## Build + publish the web app to S3/CloudFront (needs ZERACLE_WEB_BUCKET, ZERACLE_WEB_DISTRIBUTION_ID)
	cd $(WEB_DIR) && yarn deploy:pi

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
# EC2 sandbox. One exception worth knowing: install-mock-feeds-chain-guard
# binds local port 8597 for a stub RPC (still no outside network).
test: ## Run the offline shell tests (lib/test + sandbox-local/test)
	@fail=0; \
	for t in lib/test/*.test.sh sandbox-local/test/*.test.sh; do \
	  [ -f "$$t" ] || continue; \
	  echo "== $$t"; \
	  bash "$$t" || fail=1; \
	done; \
	exit $$fail

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
