# Top-level GNUmakefile for gershwin-windowmanager

# .PHONY marks targets that are not real files and forces make to run
# their recipes unconditionally. Here it ensures top-level targets
# like `install` (implemented in sub-Makefiles and invoked via
# recursive `$(MAKE) -C <dir>`) are always executed even if files of
# the same name exist in the tree.
.PHONY: all XCBKit WindowManager clean install

all: XCBKit WindowManager

XCBKit:
	$(MAKE) -C XCBKit -f GNUmakefile

WindowManager: XCBKit
	$(MAKE) -C WindowManager -f GNUmakefile

install: XCBKit WindowManager
	$(MAKE) -C XCBKit -f GNUmakefile install
	$(MAKE) -C WindowManager -f GNUmakefile install

clean:
	$(MAKE) -C XCBKit -f GNUmakefile clean
	$(MAKE) -C WindowManager -f GNUmakefile clean
