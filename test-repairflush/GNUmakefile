include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_OBJ_DIR=./obj

TEST_TOOL_NAME = repairflush

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated

repairflush_OBJC_FILES = repairflush.m

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
