APP_NAME = piles
BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications/$(BUNDLE)
BUILD_DIR = .build/release
LOCAL_BIN = $(HOME)/.local/bin
CTL_LINK = $(LOCAL_BIN)/piles-ctl
BUNDLE_ID = com.piles.app
CODESIGN_IDENTITY ?= -
CODESIGN_REQUIREMENTS ?= =designated => identifier "$(BUNDLE_ID)"

.PHONY: build debug test check agent-test agent-build agent-check install start clean dist benchmark link-ctl

build:
	swift build --product piles -c release
	swift build --product piles-ctl -c release
	$(MAKE) link-ctl CTL_SOURCE="$(CURDIR)/$(BUILD_DIR)/piles-ctl"

link-ctl:
	@test -n "$(CTL_SOURCE)" || (echo "link-ctl: CTL_SOURCE not set" && exit 1)
	@mkdir -p "$(LOCAL_BIN)"
	@ln -sf "$(CTL_SOURCE)" "$(CTL_LINK)"
	@echo "linked $(CTL_LINK) -> $(CTL_SOURCE)"
	@case ":$$PATH:" in *:"$(LOCAL_BIN)":*) ;; \
		*) echo 'add to PATH: export PATH="$(LOCAL_BIN):$$PATH"';; esac

debug:
	swift run piles

test:
	swift build --product piles-tests
	.build/debug/piles-tests

check: test build

# Cursor's agent sandbox blocks SwiftPM's sandbox-exec; --disable-sandbox avoids that.
agent-test:
	swift build --disable-sandbox --product piles-tests
	.build/debug/piles-tests

agent-build:
	swift build --disable-sandbox --product piles -c release
	swift build --disable-sandbox --product piles-ctl -c release

agent-check: agent-test agent-build

install: build
	@if [ ! -d "$(INSTALL_DIR)" ]; then \
		mkdir -p $(INSTALL_DIR)/Contents/MacOS; \
		cp Info.plist $(INSTALL_DIR)/Contents/; \
		echo "fresh install to $(INSTALL_DIR)"; \
		echo "grant accessibility permission in system settings, then: open /Applications/$(APP_NAME).app"; \
	fi
	cp $(BUILD_DIR)/$(APP_NAME) $(BUILD_DIR)/piles-ctl $(INSTALL_DIR)/Contents/MacOS/
	codesign --force --sign "$(CODESIGN_IDENTITY)" --requirements '$(CODESIGN_REQUIREMENTS)' $(INSTALL_DIR)
	$(MAKE) link-ctl CTL_SOURCE="$(INSTALL_DIR)/Contents/MacOS/piles-ctl"
	@echo "updated $(INSTALL_DIR)"

start: install
	@if pgrep -x "$(APP_NAME)" >/dev/null; then \
		pkill -TERM -x "$(APP_NAME)"; \
		while pgrep -x "$(APP_NAME)" >/dev/null; do sleep 0.1; done; \
	fi
	open "$(INSTALL_DIR)"

dist: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Info.plist $(BUNDLE)/Contents/
	cp $(BUILD_DIR)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	codesign --force --sign "$(CODESIGN_IDENTITY)" --requirements '$(CODESIGN_REQUIREMENTS)' $(BUNDLE)
	zip -r $(APP_NAME).zip $(BUNDLE)
	@shasum -a 256 $(APP_NAME).zip

clean:
	swift package clean
	rm -rf $(BUNDLE) $(APP_NAME).zip

benchmark:
	bash scripts/benchmark.sh run

uninstall:
	rm -rf "$(INSTALL_DIR)"
	rm -f "$(CTL_LINK)"
