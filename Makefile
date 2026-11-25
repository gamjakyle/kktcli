# kktcli convenience targets. Building uses `swift build` directly (see AGENTS.md).

.PHONY: test-core

# Optional SwiftPM build directory, e.g. `make test-core BUILD_PATH=.build-next`.
BUILD_PATH ?=
BUILD_PATH_FLAG := $(if $(BUILD_PATH),--build-path "$(BUILD_PATH)",)

# Swift Testing ships with the Command Line Tools, but SwiftPM does not add its framework
# and interop library search paths there; pass them explicitly in that setup.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer

test-core: ## Run the pure-logic unit tests. Never touches KakaoTalk.
	@if [ "$$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "$(CLT_DEV)/Frameworks/Testing.framework" ]; then \
		swift test -j 2 $(BUILD_PATH_FLAG) -Xswiftc -F -Xswiftc "$(CLT_DEV)/Frameworks" -Xlinker -F -Xlinker "$(CLT_DEV)/Frameworks" \
			-Xlinker -rpath -Xlinker "$(CLT_DEV)/Frameworks" -Xlinker -rpath -Xlinker "$(CLT_DEV)/usr/lib"; \
	else \
		swift test -j 2 $(BUILD_PATH_FLAG); \
	fi
