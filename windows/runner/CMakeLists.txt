cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# === CEF native bridge ======================================================
# Owns the CEF lifecycle behind a pure C ABI (see cef_bridge.h). The runner exe
# uses it for the early process bootstrap and Dart loads the very same DLL
# through FFI to drive browsers at runtime.
add_library(cef_bridge SHARED
  "cef_bridge.cpp"
  "cef_app.cpp"
)

# Applies CEF's own compile/link settings: include path, /std:c++20, /GR-,
# _HAS_EXCEPTIONS=0, WINVER, the CEF warning suppressions and the linker
# flags that delay-load libcef.dll.
#
# Deliberately does NOT use apply_standard_settings(): that helper forces
# /EHsc + _HAS_EXCEPTIONS=0 together with /W4 /WX on every translation unit,
# which conflicts with the CEF headers.
SET_LIBRARY_TARGET_PROPERTIES(cef_bridge)

# Marks the exported C ABI entry points. The runner exe and Dart FFI share this
# header, so it must never pull in a CEF header itself.
target_compile_definitions(cef_bridge PRIVATE "CEF_BRIDGE_EXPORTS")

target_link_libraries(cef_bridge PRIVATE
  libcef_lib
  libcef_dll_wrapper
  ${CEF_STANDARD_LIBS}
)

# The runner needs the bridge for the CEF process bootstrap. Both targets share
# this binary directory, so cef_bridge.dll is produced next to the executable.
add_dependencies(${BINARY_NAME} cef_bridge)
target_link_libraries(${BINARY_NAME} PRIVATE cef_bridge)

# === CEF runtime deployment =================================================
# libcef.dll, its helper DLLs, the .pak resource bundles, icudtl.dat and the
# locales directory all have to sit next to the executable. COPY_FILES() is the
# macro CEF uses for its own samples and already understands the current
# distribution layout (resources live in <CEF_ROOT>/Resources, binaries in
# <CEF_ROOT>/<Debug|Release>).
#
# This POST_BUILD step runs for every build, and because CMake's install step
# (which Flutter drives for `flutter build windows`) writes into this very same
# directory without pruning unknown files, a separate install() rule would only
# duplicate a ~250 MB copy.
COPY_FILES("${BINARY_NAME}" "${CEF_BINARY_FILES}" "${CEF_DIST_BINARY_DIR}"
           "$<TARGET_FILE_DIR:${BINARY_NAME}>")
COPY_FILES("${BINARY_NAME}" "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}"
           "$<TARGET_FILE_DIR:${BINARY_NAME}>")
