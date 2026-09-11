# All commands run from repo root. .env is the single source of secrets:
# docker compose loads it directly, OpenTofu gets it as TF_VAR_*.

SHELL := /bin/bash
COMPOSE := docker compose --env-file .env -f compose/docker-compose.yml
# Separate compose project — see the header of compose/gitea.yaml for why.
GITEA_COMPOSE := docker compose --env-file .env -f compose/gitea.yaml
SPACE_DIR := tofu/space
CP_DIR := tofu/control-plane
PH_DIR := tofu/platform-hub
APP_DIR := tofu/app-randomquotes
AGENT_DIR := tofu/k8s-agent
ARGO_DIR := tofu/argocd

# Forwarded to every `tofu apply` / `tofu destroy`. Default empty so
# interactive use still prompts for `yes`. Pass `-auto-approve` for
# non-interactive runs:  `make apply TOFU_APPLY_FLAGS=-auto-approve`
TOFU_APPLY_FLAGS ?=

# Load .env (secrets + per-target URL/key) and export TF_VAR_* for OpenTofu.
# Non-sensitive values come from each stack's committed defaults.auto.tfvars.
# OCTOPUS_URL is per-worktree: local has http://localhost:8090, SaaS has the
# https://<id>.octopus.app URL.
#
# Demo branches are OPT-IN. Previously every make target ran `git ls-remote`
# against origin and fed whatever demo/* branches existed straight into
# tofu, which meant app-apply always tried to build all of them — including
# the ones whose OCL references channels/step templates that don't exist in
# a fresh Space. It also put a network call in the path of every single
# target, which is the last thing you want in offline mode. Now:
#   DEMO_BRANCHES='["demo/canary"]'   explicit list, wins over everything
#   DEMO_BRANCHES_DISCOVER=true       auto-discover from origin (old behaviour)
#   neither set                       no demo projects at all (default)
define load_env
	set -a; \
	[ -f .env ] || { echo "Missing .env — copy .env.example and fill it in."; exit 1; }; \
	source .env; set +a; \
	[ -n "$$OCTOPUS_URL" ] || { echo "OCTOPUS_URL is unset in .env (e.g. http://localhost:8090 or https://<id>.octopus.app)"; exit 1; }; \
	if [ -n "$${DEMO_BRANCHES:-}" ]; then \
	  DEMO_BRANCHES="$$DEMO_BRANCHES"; \
	elif [ "$${DEMO_BRANCHES_DISCOVER:-false}" = "true" ]; then \
	  DEMO_BRANCHES=$$(git ls-remote --heads origin 'demo/*' 2>/dev/null | awk '{print $$2}' | sed 's|refs/heads/||' | jq -R . | jq -s -c . 2>/dev/null || echo '[]'); \
	else \
	  DEMO_BRANCHES='[]'; \
	fi; \
	export TF_VAR_octopus_url="$$OCTOPUS_URL" \
	       TF_VAR_octopus_api_key="$$OCTOPUS_API_KEY" \
	       TF_VAR_github_pat="$$GITHUB_PAT" \
	       TF_VAR_octopus_url_from_cluster="$${OCTOPUS_URL_FROM_CLUSTER:-http://host.docker.internal:8090}" \
	       TF_VAR_octopus_polling_url_from_cluster="$${OCTOPUS_POLLING_URL_FROM_CLUSTER:-https://host.docker.internal:10943}" \
	       TF_VAR_enable_platform_hub="$${OCTOPUS_PLATFORM_HUB_ENABLED:-true}" \
	       TF_VAR_space_is_default="$${OCTOPUS_SPACE_IS_DEFAULT:-true}" \
	       TF_VAR_demo_branches="$$DEMO_BRANCHES" \
	       TF_VAR_sealed_secrets_tls_b64="$${SEALED_SECRETS_TLS_B64:-}" \
	       TF_VAR_applicationset_github_pat="$${GITHUB_PAT:-}"; \
	if [ "$${GITEA_ENABLED:-false}" = "true" ]; then \
	  [ -n "$${GITEA_TOKEN:-}" ] || { echo "GITEA_ENABLED=true but GITEA_TOKEN is empty — run 'make gitea-bootstrap'."; exit 1; }; \
	  export TF_VAR_github_username="$${GITEA_ADMIN_USER:-admin}" \
	         TF_VAR_github_pat="$$GITEA_TOKEN"; \
	fi;
endef

.PHONY: help \
        up down logs ps nuke \
        gitea-up gitea-down gitea-nuke gitea-logs gitea-bootstrap gitea-push \
        gitea-enable gitea-disable gitea-mirror open \
        bootstrap master-key mint-api-key ensure-api-key \
        space-init space-plan space-apply space-destroy space-fmt space-validate \
        cp-init cp-plan cp-apply cp-destroy cp-fmt cp-validate \
        ph-init ph-plan ph-apply ph-destroy ph-fmt ph-validate \
        template-publish template-share \
        app-init app-plan app-apply app-destroy app-fmt app-validate \
        agent-init agent-plan agent-apply agent-destroy agent-fmt agent-validate \
        argo-init argo-plan argo-apply argo-destroy argo-fmt argo-validate \
        fmt validate apply destroy rebuild

help:
	@echo "compose/              : up | down | logs | ps | nuke      (local self-host only)"
	@echo "local gitea (offline) : gitea-up | gitea-bootstrap | gitea-push | gitea-logs | gitea-down | gitea-nuke"
	@echo "  git backend switch  : gitea-enable (point lab at gitea) | gitea-disable (back to github)"
	@echo "  sync from upstream  : gitea-mirror [REFS=\"main demo/x\"]  (github -> gitea; needs network)"
	@echo "  local dev push      : gitea-push  (your working commit -> gitea)"
	@echo "open                  : open Octopus + Argo CD + Gitea in your browser (skips anything that's down)"
	@echo "bootstrap             : bootstrap (fresh clone → running lab) | master-key | mint-api-key (local-only)"
	@echo "deploys come from CI: push to main on github → .github/workflows/build.yml → release.yml"
	@echo "tofu/space/           : space-init | space-plan | space-apply | space-destroy | space-fmt | space-validate"
	@echo "tofu/control-plane/   : cp-init | cp-plan | cp-apply | cp-destroy | cp-fmt | cp-validate"
	@echo "tofu/platform-hub/    : ph-init | ph-plan | ph-apply | ph-destroy | ph-fmt | ph-validate"
	@echo "process templates     : template-publish TEMPLATE=<slug> VERSION=<semver> | template-share TEMPLATE=<slug>"
	@echo "tofu/app-randomquotes/: app-init | app-plan | app-apply | app-destroy | app-fmt | app-validate"
	@echo "tofu/k8s-agent/       : agent-init | agent-plan | agent-apply | agent-destroy | agent-fmt | agent-validate"
	@echo "tofu/argocd/          : argo-init | argo-plan | argo-apply | argo-destroy | argo-fmt | argo-validate"
	@echo "convenience           : fmt (all) | validate (all) | apply (space,cp,ph,app,agent,argo) | destroy (rev) | rebuild (destroy + apply, non-interactive)"
	@echo ""
	@echo "non-interactive flags:"
	@echo "  make nuke FORCE=1                              # skip the 'are you sure' prompt"
	@echo "  make apply TOFU_APPLY_FLAGS=-auto-approve      # skip 'yes' prompts on every tofu apply"

# --- compose/ -------------------------------------------------------------

# Licence is read straight from .env as OCTOPUS_SERVER_BASE64_LICENSE — docker
# compose's --env-file picks it up and the Octopus image's install.sh applies
# it on boot. Encode once with `base64 -i license.xml | tr -d '\n'` and paste
# into .env. If the var is unset/empty the licence step is skipped (paste via
# UI under Configuration → License).
up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f octopus

ps:
	$(COMPOSE) ps

nuke:
	@if [ -z "$$FORCE" ]; then \
		read -p "This deletes the local Octopus DB. Continue? [y/N] " ans && \
		[ "$$ans" = "y" ] || [ "$$ans" = "yes" ]; \
	fi
	$(COMPOSE) down -v --remove-orphans

# --- local gitea (offline git, opt-in) ------------------------------------
#
# Ordering matters: gitea joins the main stack's network as an external
# network, so `make up` has to have created it first. gitea-up says so
# rather than failing with docker's less obvious "network not found".

gitea-up:
	@docker network inspect selfhost-setup_default >/dev/null 2>&1 || { \
		echo "Network selfhost-setup_default doesn't exist yet — run 'make up' first."; exit 1; }
	$(GITEA_COMPOSE) up -d --wait
	@echo "Gitea up at http://localhost:3000 — now run 'make gitea-bootstrap'"

gitea-bootstrap:
	$(load_env) ./compose/configure-gitea.sh

# Push the current commit to gitea/main. The lab reads from gitea, so any
# OCL or gitops change has to land here to take effect, same as pushing to
# github in the online setup.
gitea-push:
	@if [ -n "$$(git status --porcelain -- gitops .octopus)" ]; then \
		echo "Uncommitted changes under gitops/ or .octopus/ — git pushes commits, not your working tree,"; \
		echo "so these would NOT reach Gitea and Octopus/Argo would keep reading the old URLs:"; \
		git status --short -- gitops .octopus | sed 's/^/  /'; \
		echo "Commit them first (e.g. git commit -am 'Point lab at local Gitea'), or re-run with FORCE=1."; \
		[ -n "$$FORCE" ] || exit 1; \
	fi
	$(load_env) git push "http://$${GITEA_ADMIN_USER:-admin}:$${GITEA_TOKEN}@localhost:3000/$${GITEA_ADMIN_USER:-admin}/$${GITEA_REPO:-octopus-iac-lab}.git" HEAD:refs/heads/main

# Reconcile Gitea from upstream (github) — the "pull relevant changes into
# gitea" step. Reads UPSTREAM refs, not your working tree, so unfinished
# local work can't leak into the lab. The only target here that needs
# internet, by design.
#   make gitea-mirror                      # refs from GITEA_MIRROR_REFS (default: main)
#   make gitea-mirror REFS="main demo/canary"
gitea-mirror:
	$(load_env) ./compose/mirror-to-gitea.sh $(REFS)

# Point Octopus CaC, Platform Hub, and Argo CD at Gitea (or back at github).
# Rewrites gitops/ + .octopus/ URLs in the working tree and generates
# per-stack gitea.auto.tfvars — see the script header for why both are needed.
gitea-enable:
	$(load_env) ./compose/set-git-backend.sh gitea

gitea-disable:
	$(load_env) ./compose/set-git-backend.sh github

gitea-logs:
	$(GITEA_COMPOSE) logs -f gitea

# Open Octopus + Argo CD + Gitea in the default browser, skipping whatever
# isn't currently up.
open:
	@./compose/open-uis.sh

gitea-down:
	$(GITEA_COMPOSE) down

gitea-nuke:
	@if [ -z "$$FORCE" ]; then \
		read -p "This deletes the local Gitea instance and all repos in it. Continue? [y/N] " ans && \
		[ "$$ans" = "y" ] || [ "$$ans" = "yes" ]; \
	fi
	$(GITEA_COMPOSE) down -v --remove-orphans

# --- tofu/space/ ----------------------------------------------------------

space-init:
	cd $(SPACE_DIR) && tofu init

space-plan:
	$(load_env) cd $(SPACE_DIR) && tofu plan

space-apply:
	$(load_env) cd $(SPACE_DIR) && tofu apply $(TOFU_APPLY_FLAGS)

space-destroy:
	$(load_env) cd $(SPACE_DIR) && tofu destroy $(TOFU_APPLY_FLAGS)

space-fmt:
	cd $(SPACE_DIR) && tofu fmt -recursive

space-validate:
	cd $(SPACE_DIR) && tofu validate

# --- tofu/control-plane/ --------------------------------------------------

cp-init:
	cd $(CP_DIR) && tofu init

cp-plan:
	$(load_env) cd $(CP_DIR) && tofu plan

cp-apply:
	$(load_env) cd $(CP_DIR) && tofu apply $(TOFU_APPLY_FLAGS)

cp-destroy:
	$(load_env) cd $(CP_DIR) && tofu destroy $(TOFU_APPLY_FLAGS)

cp-fmt:
	cd $(CP_DIR) && tofu fmt -recursive

cp-validate:
	cd $(CP_DIR) && tofu validate

# --- tofu/platform-hub/ ---------------------------------------------------

ph-init:
	cd $(PH_DIR) && tofu init

ph-plan:
	$(load_env) cd $(PH_DIR) && tofu plan

ph-apply:
	$(load_env) cd $(PH_DIR) && tofu apply $(TOFU_APPLY_FLAGS)

ph-destroy:
	$(load_env) cd $(PH_DIR) && tofu destroy $(TOFU_APPLY_FLAGS)

ph-fmt:
	cd $(PH_DIR) && tofu fmt -recursive

ph-validate:
	cd $(PH_DIR) && tofu validate

# Publish + share a process template via the Platform Hub REST API
# (no provider resource in octopusdeploy ~> 1.12 yet — null_resource bait).
# Usage: make template-publish TEMPLATE=k8s-tenanted-app VERSION=1.0.0 [BRANCH=main]
#        make template-share   TEMPLATE=k8s-tenanted-app                [BRANCH=main]
TEMPLATE_BRANCH ?= main

template-publish:
	@test -n "$(TEMPLATE)" || { echo "TEMPLATE=<slug> required"; exit 2; }
	@test -n "$(VERSION)" || { echo "VERSION=<semver> required"; exit 2; }
	$(load_env) curl -sS -f -X POST \
	  "$$OCTOPUS_URL/api/platformhub/refs%2Fheads%2F$(TEMPLATE_BRANCH)/processtemplates/$(TEMPLATE)/versions" \
	  -H "X-Octopus-ApiKey: $$OCTOPUS_API_KEY" \
	  -H "Content-Type: application/json" \
	  --data '{"ProcessTemplateSlug":"$(TEMPLATE)","GitRef":"refs/heads/$(TEMPLATE_BRANCH)","Version":"$(VERSION)","IsPreRelease":false}' \
	  | python3 -m json.tool

template-share:
	@test -n "$(TEMPLATE)" || { echo "TEMPLATE=<slug> required"; exit 2; }
	$(load_env) curl -sS -f -X POST \
	  "$$OCTOPUS_URL/api/platformhub/refs%2Fheads%2F$(TEMPLATE_BRANCH)/processtemplates/$(TEMPLATE)/share" \
	  -H "X-Octopus-ApiKey: $$OCTOPUS_API_KEY" \
	  -H "Content-Type: application/json" \
	  --data '{"ProcessTemplateSlug":"$(TEMPLATE)","GitRef":"refs/heads/$(TEMPLATE_BRANCH)","ShareToAllSpaces":true,"IndividuallySharedSpaceIds":[]}'

# --- tofu/app-randomquotes/ -----------------------------------------------

app-init:
	cd $(APP_DIR) && tofu init

app-plan:
	$(load_env) cd $(APP_DIR) && tofu plan

app-apply:
	$(load_env) cd $(APP_DIR) && tofu apply $(TOFU_APPLY_FLAGS)

app-destroy:
	$(load_env) cd $(APP_DIR) && tofu destroy $(TOFU_APPLY_FLAGS)

app-fmt:
	cd $(APP_DIR) && tofu fmt -recursive

app-validate:
	cd $(APP_DIR) && tofu validate

# --- tofu/k8s-agent/ ------------------------------------------------------

agent-init:
	cd $(AGENT_DIR) && tofu init

agent-plan:
	$(load_env) cd $(AGENT_DIR) && tofu plan

agent-apply:
	$(load_env) cd $(AGENT_DIR) && tofu apply $(TOFU_APPLY_FLAGS)

agent-destroy:
	$(load_env) cd $(AGENT_DIR) && tofu destroy $(TOFU_APPLY_FLAGS)

agent-fmt:
	cd $(AGENT_DIR) && tofu fmt -recursive

agent-validate:
	cd $(AGENT_DIR) && tofu validate

# --- tofu/argocd/ ---------------------------------------------------------

argo-init:
	cd $(ARGO_DIR) && tofu init

argo-plan:
	$(load_env) cd $(ARGO_DIR) && tofu plan

argo-apply:
	$(load_env) cd $(ARGO_DIR) && tofu apply $(TOFU_APPLY_FLAGS)

argo-destroy:
	$(load_env) cd $(ARGO_DIR) && tofu destroy $(TOFU_APPLY_FLAGS)

argo-fmt:
	cd $(ARGO_DIR) && tofu fmt -recursive

argo-validate:
	cd $(ARGO_DIR) && tofu validate

# --- convenience ----------------------------------------------------------

fmt: space-fmt cp-fmt ph-fmt app-fmt agent-fmt argo-fmt
validate: space-validate cp-validate ph-validate app-validate agent-validate argo-validate

# Apply order: space → cp → ph → app → agent → argo. Every downstream stack
# reads space_id from tofu/space/ via terraform_remote_state, so space must
# apply first. App reads cp outputs too. argo reads space + cp + app
# (Application module references project slug from app stack). ensure-api-key
# runs first so a stale token (e.g. after a local DB wipe) is auto-recovered
# before any tofu work starts.
apply: ensure-api-key space-apply cp-apply ph-apply app-apply agent-apply argo-apply

# Destroy in reverse — argo first, space last. Destroying space cascades on
# the Octopus side (deleting the Space removes all child resources), but the
# *terraform state* of downstream stacks still references those resources, so
# we destroy them in dependency order to keep state coherent.
destroy: ensure-api-key argo-destroy agent-destroy app-destroy ph-destroy cp-destroy space-destroy

# Nuke-and-rebuild — non-interactive. Runs the full destroy chain then the
# full apply chain, both with -auto-approve, so two worktrees can be
# rebuilt in parallel without each prompting for confirmation:
#   make -C ../octopus-iac-lab-saas rebuild & make rebuild & wait
# Sandbox semantics — don't add this target to anything you can't afford to
# nuke without a second thought.
rebuild: ensure-api-key
	@$(load_env) \
	for d in $(ARGO_DIR) $(AGENT_DIR) $(APP_DIR) $(PH_DIR) $(CP_DIR) $(SPACE_DIR); do \
	  echo "=== destroy $$d ==="; \
	  ( cd $$d && tofu destroy -auto-approve ) || exit $$?; \
	done; \
	for d in $(SPACE_DIR) $(CP_DIR) $(PH_DIR) $(APP_DIR) $(AGENT_DIR) $(ARGO_DIR); do \
	  echo "=== apply $$d ==="; \
	  ( cd $$d && tofu apply -auto-approve ) || exit $$?; \
	done

# --- bootstrap helpers ----------------------------------------------------

# First-time bring-up from a fresh clone. Idempotent — safe to re-run.
# Local self-host only (mint-api-key needs the admin/Password01! login).
bootstrap:
	@[ -f .env ] || { cp .env.example .env && echo ".env created from .env.example"; }
	@CURRENT=$$(grep '^MASTER_KEY=' .env | cut -d= -f2-); \
	  if [ -z "$$CURRENT" ] || [ "$$CURRENT" = "CHANGE_ME" ]; then $(MAKE) master-key; fi
	@PAT=$$(grep '^GITHUB_PAT=' .env | cut -d= -f2-); \
	  case "$$PAT" in ""|ghp_XXX*) \
	    echo "GITHUB_PAT not set in .env — needed for CaC commits + the GHCR feed."; \
	    echo "Make a classic PAT (repo + read:packages), put it in .env, re-run 'make bootstrap'."; \
	    echo "Note: CaC pushes to cac_repo_url (tofu/app-randomquotes/defaults.auto.tfvars)."; \
	    echo "If you cloned this lab, you can't push to the original repo — point cac_repo_url"; \
	    echo "at a GitHub repo you own and give the PAT write access to it."; \
	    exit 1 ;; \
	  esac
	@echo "Booting compose stack; waiting for Octopus to be healthy ..."
	$(COMPOSE) up -d --wait octopus
	$(COMPOSE) up -d
	$(MAKE) mint-api-key
	@kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 || \
	  echo "WARNING: no reachable Kubernetes cluster — agent + argo stacks will fail. Enable Kubernetes in Docker Desktop for the full lab."
	$(MAKE) space-init cp-init ph-init app-init agent-init argo-init
	$(MAKE) apply TOFU_APPLY_FLAGS=-auto-approve
	@echo ""
	@echo "Done. Octopus UI: http://localhost:8090  (admin / Password01!)"

# Generate a fresh 32-byte MASTER_KEY into .env. First-time setup only —
# refuses to overwrite an existing key (would orphan any data encrypted with
# the old one). To start fresh, see the manual wipe steps in README.md.
master-key:
	@CURRENT=$$(grep '^MASTER_KEY=' .env 2>/dev/null | cut -d= -f2-); \
	if [ -n "$$CURRENT" ] && [ "$$CURRENT" != "CHANGE_ME" ]; then \
		echo "MASTER_KEY already set in .env. Refusing to overwrite — see manual wipe steps in README.md."; \
		exit 1; \
	fi; \
	KEY=$$(openssl rand -base64 32); \
	if grep -q '^MASTER_KEY=' .env 2>/dev/null; then \
		sed -i '' "s|^MASTER_KEY=.*|MASTER_KEY=$$KEY|" .env; \
	else \
		echo "MASTER_KEY=$$KEY" >> .env; \
	fi; \
	echo "MASTER_KEY generated."

# Log in as admin (admin/Password01!) and mint a fresh API key, write it to
# .env. Idempotent — old keys aren't revoked. Local self-host only; SaaS API
# keys must be minted in the UI (no admin/password to log in with).
mint-api-key:
	@COOKIE=$$(mktemp); \
	curl -sf -c "$$COOKIE" -X POST -H "Content-Type: application/json" \
	     -d '{"Username":"admin","Password":"Password01!"}' \
	     http://localhost:8090/api/users/login > /dev/null \
	  || { echo "Login failed — is Octopus up at http://localhost:8090?"; rm "$$COOKIE"; exit 1; }; \
	USER_ID=$$(curl -sf -b "$$COOKIE" http://localhost:8090/api/users/me | jq -r .Id); \
	CSRF=$$(grep -oE 'Octopus-Csrf-Token_[^[:space:]]+\s+[^[:space:]]+' "$$COOKIE" | awk '{print $$2}' | tail -1); \
	KEY=$$(curl -sf -b "$$COOKIE" -H "X-Octopus-Csrf-Token: $$CSRF" \
	     -H "Content-Type: application/json" -X POST \
	     -d '{"Purpose":"make mint-api-key"}' \
	     "http://localhost:8090/api/users/$$USER_ID/apikeys" | jq -r .ApiKey); \
	rm "$$COOKIE"; \
	if grep -q '^OCTOPUS_API_KEY=' .env; then \
		sed -i '' "s|^OCTOPUS_API_KEY=.*|OCTOPUS_API_KEY=$$KEY|" .env; \
	else \
		echo "OCTOPUS_API_KEY=$$KEY" >> .env; \
	fi; \
	echo "OCTOPUS_API_KEY written to .env (purpose=\"make mint-api-key\")"

# Probe the current OCTOPUS_API_KEY against /api/users/me. If unauthorised:
#   - local: silently mint a fresh key (admin/Password01! login still works
#     after a DB wipe)
#   - SaaS:  fail with a pointer to the UI, since we can't mint without a
#     session
# Apply / destroy depend on this so a stale token from `make nuke` (DB
# rebuilt, .env still pointing at the old key) auto-recovers.
ensure-api-key:
	@$(load_env) \
	  if curl -sf -o /dev/null -H "X-Octopus-ApiKey: $$OCTOPUS_API_KEY" "$$OCTOPUS_URL/api/users/me"; then \
	    :; \
	  else \
	    case "$$OCTOPUS_URL" in \
	      *octopus.app*) \
	        echo "OCTOPUS_API_KEY rejected by $$OCTOPUS_URL."; \
	        echo "Mint a new one at $$OCTOPUS_URL/app#/users/me/apiKeys and update .env."; \
	        exit 1 ;; \
	      *) \
	        echo "OCTOPUS_API_KEY rejected — local DB likely rebuilt. Minting fresh."; \
	        $(MAKE) mint-api-key ;; \
	    esac; \
	  fi
