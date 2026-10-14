PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin/iterm-peek
LINEAR_TEAMS ?= OL

# Command Line Tools ships two modulemaps that both define SwiftBridging, which
# breaks every swiftc build. Hide the duplicate with a VFS overlay instead of
# editing the system install.
CLT_MODULEMAP := /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
ifneq ($(wildcard /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap),)
SWIFT_OVERLAY := -vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml
OVERLAY_DEP := build/overlay.yaml
endif

.PHONY: build install uninstall

build: build/iterm-peek

build/iterm-peek: peek.swift $(OVERLAY_DEP)
	@mkdir -p build
	swiftc -O -swift-version 5 $(SWIFT_OVERLAY) peek.swift -o $@

build/overlay.yaml:
	@mkdir -p build
	@touch build/empty.modulemap
	@printf '{"version":0,"case-sensitive":"false","roots":[{"type":"file","name":"%s","external-contents":"%s"}]}\n' \
		"$(CLT_MODULEMAP)" "$(CURDIR)/build/empty.modulemap" > $@

install: build
	@mkdir -p $(dir $(BIN))
	install -m 755 build/iterm-peek $(BIN)
	uv run install_rules.py $(BIN) $(LINEAR_TEAMS)

uninstall:
	uv run install_rules.py --uninstall
	rm -f $(BIN)
