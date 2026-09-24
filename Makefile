BIN        := MouseTrace
SRC        := MouseTrace.swift
FRAMEWORKS := -framework AppKit -framework CoreGraphics -framework IOKit
IDENTIFIER := com.joon-aca.mousetrace
# A real signing identity keeps the Input Monitoring grant valid across rebuilds;
# ad-hoc signatures change every build, so macOS would forget the grant each time.
SIGN_ID    := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')

LABEL      := com.joon-aca.mousetrace.watch
DOMAIN     := gui/$(shell id -u)
INSTALLED  := $(HOME)/.local/bin/$(BIN)
PLIST      := $(HOME)/Library/LaunchAgents/$(LABEL).plist
WATCH_LOG  := $(HOME)/Library/Logs/MouseTrace/watch.log

.DEFAULT_GOAL := help
.PHONY: help run install uninstall status

help:
	@echo "make run        trace every click live (Ctrl-C to stop; appends to mouse-trace.log)"
	@echo "make install    build + (re)start the stuck-button watchdog at login"
	@echo ""
	@echo "make status     watchdog state and recent log"
	@echo "make uninstall  stop and remove the watchdog"

$(BIN): $(SRC)
	xcrun swiftc $(SRC) -o $@ $(FRAMEWORKS)
ifeq ($(SIGN_ID),)
	@echo "warning: no Apple Development identity; ad-hoc signing (Input Monitoring must be re-granted after each rebuild)"
	codesign --force --sign - --identifier $(IDENTIFIER) $@
else
	codesign --force --sign "$(SIGN_ID)" --identifier $(IDENTIFIER) $@
endif

run: $(BIN)
	@echo "If macOS asks, allow your terminal in Privacy & Security > Accessibility and Input Monitoring."
	./$(BIN) 2>&1 | tee -a mouse-trace.log

# Idempotent: replaces a running watchdog with the freshly built one.
install: $(BIN)
	mkdir -p "$(dir $(INSTALLED))" "$(dir $(PLIST))" "$(dir $(WATCH_LOG))"
	install -m 755 $(BIN) "$(INSTALLED)"
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BIN@|$(INSTALLED)|' -e 's|@LOG@|$(WATCH_LOG)|' launchd.plist.in > "$(PLIST)"
	plutil -lint "$(PLIST)"
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) "$(PLIST)"
	@sleep 1
	@$(MAKE) --no-print-directory status

status:
	@if launchctl print $(DOMAIN)/$(LABEL) >/dev/null 2>&1; then \
		launchctl print $(DOMAIN)/$(LABEL) | awk '/^\t(state|pid|last exit code) =/'; \
	else echo "watchdog not loaded (run: make install)"; fi
	@echo "--- $(WATCH_LOG)"
	@tail -n 5 "$(WATCH_LOG)" 2>/dev/null || true

uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f "$(PLIST)" "$(INSTALLED)"
	@echo "watchdog removed (log kept at $(WATCH_LOG))"
