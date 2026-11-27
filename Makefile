.PHONY: doctor check build debug app-icon desktop-fixture desktop-review-build desktop-review desktop-review-status desktop-review-stop performance mcp-interop-prepare mcp-interop package release publish ship ship-plan verify-release install rollback
doctor:
	python3 scripts/keydock.py doctor
check:
	python3 scripts/keydock.py check
performance:
	python3 scripts/keydock.py performance --mode query
build:
	python3 scripts/keydock.py build --profile preview --allow-dirty
debug:
	python3 scripts/keydock.py debug
app-icon:
	bash scripts/generate-app-icon.sh
desktop-fixture:
	python3 scripts/keydock.py desktop-fixture
desktop-review-build:
	python3 scripts/keydock.py desktop-review-build
desktop-review:
	python3 scripts/keydock.py desktop-review $(if $(REVIEW_ROOT),--reuse-root "$(REVIEW_ROOT)")
desktop-review-status:
	python3 scripts/keydock.py desktop-review-status --receipt "$(RECEIPT)"
desktop-review-stop:
	python3 scripts/keydock.py desktop-review-stop --receipt "$(RECEIPT)" $(if $(REVIEW_ONLY),--review-only)
mcp-interop-prepare:
	python3 scripts/keydock.py prepare-mcp-interop --python "$(MCP_PYTHON)" --output "$(MCP_OUTPUT)"
mcp-interop:
	python3 scripts/keydock.py mcp-interop --environment "$(MCP_ENVIRONMENT)" --run-name "$(MCP_RUN)" --scenario "$(or $(MCP_SCENARIO),time)"
package:
	python3 scripts/keydock.py package
release:
	python3 scripts/keydock.py release
publish:
	python3 scripts/keydock.py publish
ship:
	python3 scripts/keydock.py ship
ship-plan:
	python3 scripts/keydock.py ship --plan
verify-release:
	python3 scripts/keydock.py verify-release
install:
	python3 scripts/keydock.py install-release
rollback:
	python3 scripts/keydock.py rollback "$(RECEIPT)" --quit-running
