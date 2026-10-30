ARCHS = armv7
TARGET := iphone:clang:6.1:6.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FlareShare

FlareShare_FILES = Tweak.x
FlareShare_CFLAGS = -fobjc-arc

FlareShare_FRAMEWORKS = UIKit Foundation AssetsLibrary MobileCoreServices

include $(THEOS_MAKE_PATH)/tweak.mk
