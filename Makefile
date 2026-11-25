# kmsg convenience targets.
# Building still uses `swift build` directly (see CLAUDE.md); these wrap the
# Headatever version bump script (head.yymmdd.patch). See VERSIONING.md.

BUMP := scripts/headatever.sh

.PHONY: version release release-major release-push test-core

version: ## Print the current version
	@$(BUMP) show

release: ## Patch release: bump VERSION, commit, tag v<version>
	@$(BUMP) patch

release-major: ## Head release: head+1, date=today, patch=0
	@$(BUMP) major

release-push: ## Patch release, then push commit + tag (triggers release workflow)
	@$(BUMP) patch --push

# Swift Testing ships with the Command Line Tools, but SwiftPM does not add its framework
# and interop library search paths there; pass them explicitly in that setup.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer

test-core: ## Run the pure-logic unit tests (KmsgCoreTests). Never touches KakaoTalk.
	@if [ "$$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "$(CLT_DEV)/Frameworks/Testing.framework" ]; then \
		swift test -j 2 -Xswiftc -F -Xswiftc "$(CLT_DEV)/Frameworks" -Xlinker -F -Xlinker "$(CLT_DEV)/Frameworks" \
			-Xlinker -rpath -Xlinker "$(CLT_DEV)/Frameworks" -Xlinker -rpath -Xlinker "$(CLT_DEV)/usr/lib"; \
	else \
		swift test -j 2; \
	fi
