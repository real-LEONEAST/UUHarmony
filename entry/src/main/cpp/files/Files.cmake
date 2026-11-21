add_library(uufiles SHARED "${CMAKE_CURRENT_LIST_DIR}/bridge.cpp")
target_compile_options(uufiles PRIVATE -Wall -Wextra)
target_link_options(uufiles PRIVATE -Wl,--no-undefined)
target_link_libraries(uufiles PRIVATE ace_napi.z)
