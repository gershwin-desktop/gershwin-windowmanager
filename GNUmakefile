PACKAGE_NAME = uroswm

APP_INSTALL_DIR = $(DESTDIR)/System/Library/CoreServices/Applications
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
include $(GNUSTEP_MAKEFILES)/common.make

VERSION = 0.1.0

DEPENDENCIES = XCBKit

APP_NAME = WindowManager
$(APP_NAME)_APPLICATION_ICON = WindowManager.png
$(APP_NAME)_RESOURCE_FILES = WindowManager.png
export APP_NAME

$(APP_NAME)_LD_FLAGS += -L./XCBKit/XCBKit.framework/

$(APP_NAME)_OBJC_FILES = \
		main.m \
		URSHybridEventHandler.m \
		UROSWMApplication.m \
		URSThemeIntegration.m \
		GSThemeTitleBar.m

$(APP_NAME)_HEADER_FILES = \
		URSHybridEventHandler.h \
		UROSWMApplication.h \
		URSThemeIntegration.h \
		GSThemeTitleBar.h

$(APP_NAME)_GUI_LIBS = -lXCBKit -lxcb $(shell pkg-config --libs cairo xcb)

ADDITIONAL_OBJCFLAGS = -std=c99 -g -O0 -fobjc-arc -Wall -Wno-typedef-redefinition #-Wno-unused -Werror -Wall

#LIBRARIES_DEPEND_UPON += $(shell pkg-config --libs xcb) $(FND_LIBS) $(OBJC_LIBS) $(SYSTEM_LIBS)

include $(GNUSTEP_MAKEFILES)/aggregate.make
include $(GNUSTEP_MAKEFILES)/application.make

# Custom target to modify Info-gnustep.plist after it's generated
after-WindowManager-all::
	@echo "Modifying Info-gnustep.plist to use custom principal class..."
	@sed -i.bak 's/NSPrincipalClass = "NSApplication";/NSPrincipalClass = "UROSWMApplication";/' WindowManager.app/Resources/Info-gnustep.plist
