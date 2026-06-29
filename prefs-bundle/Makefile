# Makefile — CodexPrefs.bundle (PreferenceLoader compiled preference bundle)
#
# Builds a Mach-O dylib wrapped as CodexPrefs.bundle, containing the
# CodexPrefsController PSListController subclass that hosts the Settings.app
# pane for the Codex CLI iOS port and implements the action buttons
# (Open Config Folder / Open Logs / Reset Authentication / Run Diagnostics /
# Open open.ai / Open upstream repo).
#
# Build with Theos:
#   THEOS=/path/to/theos make clean package
#
# The resulting CodexPrefs.bundle is dropped into the deb tree at
# codex-ios/var/jb/Library/PreferenceBundles/CodexPrefs.bundle and signed
# with ldid by the deb's postinst.

TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CodexPrefs
CodexPrefs_FILES = CodexPrefsController.m
CodexPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CodexPrefs_FRAMEWORKS = UIKit Foundation
CodexPrefs_PRIVATE_FRAMEWORKS = Preferences
CodexPrefs_LDFLAGS = -framework Preferences

include $(THEOS_MAKE_PATH)/bundle.mk
