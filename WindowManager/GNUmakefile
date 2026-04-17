PACKAGE_NAME = uroswm

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_APPS = $(GNUSTEP_SYSTEM_SERVICES)

VERSION = 0.1.0

APP_NAME = WindowManager
$(APP_NAME)_APPLICATION_ICON = WindowManager.png
$(APP_NAME)_RESOURCE_FILES = WindowManager.png
export APP_NAME

# Include paths for the xcb abstraction layer
$(APP_NAME)_INCLUDE_DIRS = -Ixcb -Ixcb/services -Ixcb/enums -Ixcb/utils

# ── Window Manager sources ──────────────────────────────────────────

$(APP_NAME)_OBJC_FILES = \
		main.m \
		UROSWMApplication.m \
		URSHybridEventHandler.m \
		URSFocusManager.m \
		URSKeyboardManager.m \
		URSWorkareaManager.m \
		URSTitlebarController.m \
		URSSnappingMenuController.m \
		URSCompositingManager.m \
		URSRenderingContext.m \
		URSWindowSwitcher.m \
		URSWindowSwitcherOverlay.m \
		URSSnapPreviewOverlay.m \
		URSThemeIntegration.m \
		URSProfiler.m \
		GSThemeTitleBar.m \
		xcb/XCBConnection.m \
		xcb/XCBWindow.m \
		xcb/XCBFrame.m \
		xcb/XCBTitleBar.m \
		xcb/XCBScreen.m \
		xcb/XCBVisual.m \
		xcb/XCBCursor.m \
		xcb/XCBSelection.m \
		xcb/XCBRegion.m \
		xcb/XCBShape.m \
		xcb/XCBReply.m \
		xcb/XCBAttributesReply.m \
		xcb/XCBGeometryReply.m \
		xcb/XCBQueryTreeReply.m \
		xcb/services/EWMHService.m \
		xcb/services/ICCCMService.m \
		xcb/services/XCBAtomService.m \
		xcb/services/TitleBarSettingsService.m \
		xcb/utils/XCBCreateWindowTypeRequest.m \
		xcb/utils/XCBWindowTypeResponse.m \
		xcb/utils/Comparators.m \
		xcb/utils/Transformers.m

$(APP_NAME)_HEADER_FILES = \
		UROSWMApplication.h \
		URSHybridEventHandler.h \
		URSFocusManager.h \
		URSKeyboardManager.h \
		URSWorkareaManager.h \
		URSTitlebarController.h \
		URSSnappingMenuController.h \
		URSCompositingManager.h \
		URSRenderingContext.h \
		URSWindowSwitcher.h \
		URSWindowSwitcherOverlay.h \
		URSSnapPreviewOverlay.h \
		URSThemeIntegration.h \
		URSProfiler.h \
		GSThemeTitleBar.h \
		xcb/XCBConnection.h \
		xcb/XCBWindow.h \
		xcb/XCBFrame.h \
		xcb/XCBTitleBar.h \
		xcb/XCBScreen.h \
		xcb/XCBVisual.h \
		xcb/XCBCursor.h \
		xcb/XCBSelection.h \
		xcb/XCBRegion.h \
		xcb/XCBShape.h \
		xcb/XCBReply.h \
		xcb/XCBAttributesReply.h \
		xcb/XCBGeometryReply.h \
		xcb/XCBQueryTreeReply.h \
		xcb/XCBTypes.h \
		xcb/enums/EEwmh.h \
		xcb/enums/EIcccm.h \
		xcb/enums/EMousePosition.h \
		xcb/enums/EResizeDirection.h \
		xcb/enums/ETitleBarColor.h \
		xcb/enums/EXErrorMessages.h \
		xcb/services/EWMHService.h \
		xcb/services/ICCCMService.h \
		xcb/services/XCBAtomService.h \
		xcb/services/TitleBarSettingsService.h \
		xcb/utils/XCBCreateWindowTypeRequest.h \
		xcb/utils/XCBWindowTypeResponse.h \
		xcb/utils/Comparators.h \
		xcb/utils/Transformers.h

$(APP_NAME)_GUI_LIBS = \
		$(shell pkg-config --libs xcb xcb-icccm xcb-xfixes xcb-aux xcb-cursor xcb-shape) \
		-lxcb-util -lX11 -lXcomposite -lXext \
		-lxcb-composite -lxcb-render -lxcb-damage -lxcb-shm \
		-ldispatch

ADDITIONAL_OBJCFLAGS = -std=c99 -g -O0 -fobjc-arc -fblocks -Wall -Wno-typedef-redefinition

# Profiling: build with  make PROFILE=1  to enable CPU instrumentation.
# When enabled, a summary is printed every 10s and on SIGUSR1.
ifeq ($(PROFILE),1)
ADDITIONAL_OBJCFLAGS += -DURS_PROFILING=1
endif

include $(GNUSTEP_MAKEFILES)/application.make

# Patch Info-gnustep.plist to use custom NSPrincipalClass
after-WindowManager-all::
	@echo "Modifying Info-gnustep.plist to use custom principal class..."
	@sed -i.bak 's/NSPrincipalClass = "NSApplication";/NSPrincipalClass = "UROSWMApplication";/' WindowManager.app/Resources/Info-gnustep.plist

# Custom target to modify Info-gnustep.plist after it's generated
after-WindowManager-all::
	@echo "Modifying Info-gnustep.plist to use custom principal class..."
	@sed -i.bak 's/NSPrincipalClass = "NSApplication";/NSPrincipalClass = "UROSWMApplication";/' WindowManager.app/Resources/Info-gnustep.plist
