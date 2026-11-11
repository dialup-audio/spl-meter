cmake_minimum_required(VERSION 4.0)
project(spl-meter LANGUAGES OBJCXX)

set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

add_executable(${PROJECT_NAME}
    main.mm
)

target_compile_options(${PROJECT_NAME} PRIVATE -fobjc-arc)

target_link_libraries(${PROJECT_NAME}
    "-framework Cocoa"
    "-framework Foundation"
    "-framework CoreAudio"
)

set_target_properties(${PROJECT_NAME} PROPERTIES
    MACOSX_BUNDLE TRUE
    # Our own Info.plist template: adds LSUIElement so the app is a background agent
    # (no Dock or cmd-tab entry) from the moment it launches.
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_BUNDLE_NAME "SPL Meter"
    MACOSX_BUNDLE_GUI_IDENTIFIER "audio.dialup.${PROJECT_NAME}"
)
