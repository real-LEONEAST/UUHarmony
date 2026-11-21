# Separate, lazy-loaded microphone capture module. No transport or permission UI.
add_library(uumic SHARED "${CMAKE_CURRENT_LIST_DIR}/microphone.cc")
target_compile_features(uumic PRIVATE cxx_std_17)
target_compile_options(uumic PRIVATE -fno-exceptions -Wall -Wextra)
target_link_options(uumic PRIVATE -Wl,--no-undefined)
target_link_libraries(uumic PRIVATE Opus::opus ace_napi.z ohaudio)
