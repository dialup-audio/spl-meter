.DEFAULT_GOAL := build
BUILD_DIR := build

build:
	cmake -S . -B $(BUILD_DIR) -G Ninja
	cmake --build $(BUILD_DIR) -j

run: build
	open ./$(BUILD_DIR)/rew-dock-spl-meter.app

clean:
	rm -rf $(BUILD_DIR)
