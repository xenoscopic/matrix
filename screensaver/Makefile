PROJECT ?= Matrix/Matrix.xcodeproj
SCHEME ?= Matrix
CONFIGURATION ?= Release
BUILD_DIR ?= $(CURDIR)/build
DERIVED_DATA ?= $(BUILD_DIR)/DerivedData
PRODUCT_DIR := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
PRODUCT := $(PRODUCT_DIR)/Matrix.saver
INSTALL_DIR ?= $(HOME)/Library/Screen Savers

.PHONY: all clean build install

all: build

clean:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		clean
	rm -rf "$(BUILD_DIR)"

build: clean
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

install: build
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Matrix.saver"
	cp -R "$(PRODUCT)" "$(INSTALL_DIR)/"
