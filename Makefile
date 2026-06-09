BINARY   = TilerApp
BUNDLE   = TilerApp.app
CONTENTS = $(BUNDLE)/Contents
RELEASE  = .build/release

SIGN_IDENTITY ?= -

.PHONY: build app clean

build:
	swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(RELEASE)/$(BINARY)         $(CONTENTS)/MacOS/
	cp Resources/Info.plist         $(CONTENTS)/
	cp Resources/config.toml.example $(CONTENTS)/Resources/
	codesign --force --deep --sign "$(SIGN_IDENTITY)" $(BUNDLE)

clean:
	swift package clean
	rm -rf $(BUNDLE)
