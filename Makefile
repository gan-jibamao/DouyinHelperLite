TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSING = YES

# rootless 布局：/var/jb/Library/MobileSubstrate/...
# （iOS 15+ 的 Dopamine/palera1n 都是 rootless，rootful 已基本淘汰）
THEOS_PACKAGE_SCHEME = rootless
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DouyinHelperLite

DouyinHelperLite_FILES = Tweak.x \
	src/DHLFLVParser.m \
	src/DHLLiveStreamResolver.m \
	src/DHLLiveRecorder.m \
	src/DHLRecordControl.m \
	src/DHLRecordingsViewController.m

DouyinHelperLite_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/src -Wno-deprecated-declarations -Wno-unused-function
DouyinHelperLite_FRAMEWORKS = Foundation UIKit AVFoundation AVKit CoreMedia CoreVideo AudioToolbox VideoToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
