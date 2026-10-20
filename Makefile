.PHONY: check lint test validate

check: validate lint test ## Everything the plugin's own checks cover

validate: ## Validate the plugin and marketplace manifests, agents and skills
	claude plugin validate --strict .
	claude plugin validate --strict agents
	claude plugin validate --strict skills

lint: ## shellcheck the scripts, ruff the Python helpers
	uvx --from shellcheck-py shellcheck -x scripts/*.sh scripts/lib/*.sh hooks/*.sh tests/*.sh tests/fake-gh tests/fake-browser
	uvx ruff check --select E,F,W,B hooks/guard-role.py scripts/lib/manifest_listener.py tests/fake-curl

test: ## Smoke and identity tests on throwaway repositories (no network)
	tests/smoke.sh
	tests/identity.sh
