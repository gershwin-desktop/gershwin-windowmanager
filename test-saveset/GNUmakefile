# __GENERATED__ makefile marker
#

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
-include ../GNUmakefile.super

GNUSTEP_OBJ_DIR=./obj

TEST_TOOL_NAME =  nosaveset saveset

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ifeq ($(gcov),yes)
ADDITIONAL_OBJCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_OBJCCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_LDFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_TOOL_LIBS+=-lgcov
endif

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated


nosaveset_OBJC_FILES=nosaveset.m
saveset_OBJC_FILES=saveset.m

-include GNUmakefile.preamble
-include make-check.mak
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core \
	test_*.out test_*.err \
	tests.log tests.sum oldtests.log oldtests.sum


