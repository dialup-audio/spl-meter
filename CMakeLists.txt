cmake_minimum_required(VERSION 3.20)
project(rew_spl_meter LANGUAGES OBJCXX)

set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

add_executable(rew-spl-meter
    main.mm
)

target_compile_options(rew-spl-meter PRIVATE -fobjc-arc)

target_link_libraries(rew-spl-meter
    "-framework Cocoa"
    "-framework Foundation"
    "-framework CoreAudio"
)

set_target_properties(rew-spl-meter PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_BUNDLE_NAME "REW SPL"
    MACOSX_BUNDLE_GUI_IDENTIFIER "audio.dialup.rew-spl-meter"
)
