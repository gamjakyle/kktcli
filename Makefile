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

.PHONY: dist

# Release assets for the GitHub release v$(VERSION); install.sh downloads exactly these names.
VERSION := $(shell cat VERSION)
DIST_TARBALL := kktcli-$(VERSION)-macos-arm64.tar.gz

# The packaged binary is a `strip -S` copy: the debug map holds absolute build paths. The
# archive holds kktcli, LICENSE and README.en.md at its root, without owner names or xattrs.
dist: ## Build dist/kktcli-<version>-macos-arm64.tar.gz and its .sha256 (Apple silicon only).
	@if [ "$$(uname -m)" != "arm64" ]; then \
		echo "make dist: release binaries are built on Apple silicon only (uname -m: $$(uname -m))" >&2; \
		exit 1; \
	fi
	swift build -c release -j 2 $(BUILD_PATH_FLAG)
	@set -e; \
	bin_dir="$$(swift build -c release $(BUILD_PATH_FLAG) --show-bin-path)"; \
	stage="$$(mktemp -d)"; \
	trap 'rm -rf "$$stage"' EXIT; \
	strip -S -o "$$stage/kktcli" "$$bin_dir/kktcli"; \
	cp LICENSE README.en.md "$$stage/"; \
	mkdir -p dist; \
	COPYFILE_DISABLE=1 tar -czf "dist/$(DIST_TARBALL)" --uid 0 --gid 0 --numeric-owner \
		--no-xattrs --no-acls --no-fflags --no-mac-metadata -C "$$stage" kktcli LICENSE README.en.md; \
	cd dist && shasum -a 256 "$(DIST_TARBALL)" > "$(DIST_TARBALL).sha256"; \
	echo "dist/$(DIST_TARBALL)"; \
	echo "dist/$(DIST_TARBALL).sha256"; \
	echo "Upload both files to the GitHub release v$(VERSION)."
