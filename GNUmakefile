# Top-level GNUmakefile for gershwin-windowmanager

.PHONY: all XCBKit WindowManager clean

all: XCBKit WindowManager

XCBKit:
	$(MAKE) -C XCBKit -f GNUmakefile

WindowManager: XCBKit
	$(MAKE) -C WindowManager -f GNUmakefile

clean:
	$(MAKE) -C XCBKit -f GNUmakefile clean
	$(MAKE) -C WindowManager -f GNUmakefile clean
