# The SwiftUI macro plugins ship with Xcode, not with the Command Line Tools.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

APP := build/ClaudeIsland.app
DEST := $(HOME)/Applications

.PHONY: run test app install

run:
	swift run

test:
	swift test

app:
	swift build -c release
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release --show-bin-path)/ClaudeIsland" $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)

install: app
	pkill -x ClaudeIsland || true
	mkdir -p $(DEST) && rm -rf $(DEST)/ClaudeIsland.app && cp -R $(APP) $(DEST)/
	open $(DEST)/ClaudeIsland.app
