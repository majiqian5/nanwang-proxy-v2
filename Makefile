export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = DSH
DSH_FILES = $(wildcard src/*.m)
DSH_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore IOKit
DSH_CFLAGS = -fobjc-arc -Isrc
DSH_LDFLAGS = -undefined dynamic_lookup
DSH_INSTALL_PATH = /usr/lib/TweakInject

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
