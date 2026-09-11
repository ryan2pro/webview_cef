# Flutter Windows plugin that embeds CEF (Chromium Embedded Framework) browsers
# as real native child windows floating above the Flutter view.
#
# The plugin builds three native targets:
#   * <name>_plugin       the Flutter plugin shell,
#   * <name>_cef          the CEF implementation library, and
#   * <name>_subprocess   the executable that hosts CEF's sub-processes.
#
# Splitting them is not cosmetic. CEF's headers require /std:c++20, /GR- and
# _HAS_EXCEPTIONS=0 while Flutter's own plugin shell is built with /W4 /WX /EHsc,
# and CEF's delay-load linker flags are target scoped (they do not propagate to
# the consumers of a library target). Keeping all CEF code in its own DLL also
# means the plugin shell never includes a CEF header, which is what allows the
# host application to keep a completely stock runner.

cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "webview_cef_floating")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

# Library that implements the CEF side. Dart loads it through FFI; keep the name
# in sync with lib/src/native/cef_ffi_bindings.dart.
set(CEF_IMPL_NAME "${PROJECT_NAME}_cef")

# Executable that hosts CEF's renderer, GPU and utility processes. The
# implementation library derives its absolute path from the host executable and
# hands it to CEF as browser_subprocess_path; keep the name in sync with
# windows/cef/cef_bridge.cpp.
set(CEF_SUBPROCESS_NAME "${PROJECT_NAME}_subprocess")

# === CEF (Chromium Embedded Framework) ======================================
#
# The plugin owns CEF: the distribution is fetched into the plugin's
# third_party/cef by windows/scripts/fetch_cef.ps1, so a host application only
# has to run that script and never configures a CEF path of its own.
#
# CMAKE_CURRENT_SOURCE_DIR is <plugin>/windows, so ".." is the plugin root.
if(NOT DEFINED CEF_ROOT OR CEF_ROOT STREQUAL "")
  if(DEFINED ENV{CEF_ROOT} AND NOT "$ENV{CEF_ROOT}" STREQUAL "")
    set(CEF_ROOT "$ENV{CEF_ROOT}"
      CACHE PATH "CEF binary distribution used by webview_cef_floating")
  else()
    set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/cef"
      CACHE PATH "CEF binary distribution used by webview_cef_floating")
  endif()
endif()

if(NOT IS_DIRECTORY "${CEF_ROOT}/cmake")
  message(FATAL_ERROR
    "CEF binary distribution not found at '${CEF_ROOT}'.\n"
    "Fetch it first by running:\n"
    "  powershell -ExecutionPolicy Bypass -File \"${CMAKE_CURRENT_SOURCE_DIR}/scripts/fetch_cef.ps1\"")
endif()

# This CEF distribution ships x64 binaries only.
set(PROJECT_ARCH "x86_64" CACHE STRING "CEF target architecture" FORCE)

# The sandbox build turns the host into a DLL launched by bootstrap.exe, which is
# incompatible with the Flutter runner layout. Browsers are therefore created
# unsandboxed (CefSettings::no_sandbox); revisit this for a hardened build.
set(USE_SANDBOX OFF CACHE BOOL "Enable or disable use of the CEF sandbox." FORCE)

# CEF defaults to the static CRT (/MT) whereas Flutter plugins use the dynamic
# CRT (/MD, /MDd). libcef_dll_wrapper is a static library that gets linked into
# the CEF implementation DLL, so the runtime library has to match.
set(CEF_RUNTIME_LIBRARY_FLAG "/MD" CACHE STRING "CEF runtime library flag" FORCE)

list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# Defines the `libcef_dll_wrapper` static library target.
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

# Logical imported target used to link the prebuilt libcef import library.
ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")

# CEF only ships Debug and Release binaries, while Flutter also builds a Profile
# configuration. Map anything that is not Debug onto the Release binaries, since
# CEF_BINARY_DIR itself would expand to a nonexistent "Profile" directory.
set(CEF_DIST_BINARY_DIR
    "$<IF:$<CONFIG:Debug>,${CEF_BINARY_DIR_DEBUG},${CEF_BINARY_DIR_RELEASE}>")

# === CEF implementation library =============================================
#
# Windowed rendering: CEF creates real child HWNDs parented to the Flutter view.
# Dart drives them over a pure C ABI (windows/cef/cef_bridge.h), which is also
# the only interface the plugin shell and the sub-process host ever see.
add_library(${CEF_IMPL_NAME} SHARED
  "cef/cef_app.cpp"
  "cef/cef_app.h"
  "cef/cef_bridge.cpp"
  "cef/cef_bridge.h"
)

# Applies CEF's own compile/link settings: include path, /std:c++20, /GR-,
# _HAS_EXCEPTIONS=0, WINVER, the CEF warning suppressions and the linker flags
# that delay-load libcef.dll.
#
# Deliberately does NOT use apply_standard_settings(): that helper forces
# /EHsc + _HAS_EXCEPTIONS=0 together with /W4 /WX on every translation unit,
# which conflicts with the CEF headers.
SET_LIBRARY_TARGET_PROPERTIES(${CEF_IMPL_NAME})

# Marks the exported C ABI entry points. The plugin shell and Dart share this
# header, so it must never pull in a CEF header itself.
target_compile_definitions(${CEF_IMPL_NAME} PRIVATE "CEF_BRIDGE_EXPORTS")

target_link_libraries(${CEF_IMPL_NAME} PRIVATE
  libcef_lib
  libcef_dll_wrapper
  ${CEF_STANDARD_LIBS}
)

# === CEF sub-process host ===================================================
#
# CEF launches its sub-processes from this executable
# (CefSettings::browser_subprocess_path) instead of relaunching the host
# application, which is what keeps the host entry point free of CEF code.
add_executable(${CEF_SUBPROCESS_NAME} WIN32
  "subprocess/main.cpp"
)

# Executable flavour of the CEF settings above. It adds the larger initial stack
# CEF expects and delay-loads libcef.dll like the implementation library does.
SET_EXECUTABLE_TARGET_PROPERTIES(${CEF_SUBPROCESS_NAME})

target_link_libraries(${CEF_SUBPROCESS_NAME} PRIVATE
  libcef_lib
  libcef_dll_wrapper
  ${CEF_STANDARD_LIBS}
)

# === Plugin shell ===========================================================
#
# Bootstraps CEF from Flutter's plugin registration callback (which the host
# runner invokes on the process main thread) and keeps browsers parented to the
# Flutter view. It never includes a CEF header, so Flutter's own settings apply.
add_library(${PLUGIN_NAME} SHARED
  "include/webview_cef_floating/webview_cef_floating_plugin_c_api.h"
  "webview_cef_floating_plugin.cpp"
  "webview_cef_floating_plugin.h"
  "webview_cef_floating_plugin_c_api.cpp"
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# The shell drives the CEF bootstrap and publishes the host window through the
# implementation library.
target_link_libraries(${PLUGIN_NAME} PRIVATE ${CEF_IMPL_NAME})

# === Runtime deployment =====================================================
#
# libcef.dll, its helper DLLs, the .pak resource bundles, icudtl.dat and the
# locales directory all have to sit next to the host executable, because CEF
# resolves them relative to it.
#
# The bundle directory is the one the host executable is written to. BINARY_NAME
# is set by the application level CMakeLists.txt that adds this plugin as a
# subdirectory, so this is also a sanity check that the plugin is being built as
# a Flutter plugin.
if(NOT DEFINED BINARY_NAME)
  message(FATAL_ERROR
    "webview_cef_floating must be built as a Flutter plugin: BINARY_NAME is not "
    "defined, so the CEF runtime cannot be deployed next to the host executable.")
endif()

# Plain files go through the plugin's bundled libraries, the same mechanism
# Flutter uses for the plugin DLL itself, so they follow the host application's
# install prefix.
set(_cef_runtime_files)
foreach(_name IN LISTS CEF_BINARY_FILES)
  list(APPEND _cef_runtime_files "${CEF_DIST_BINARY_DIR}/${_name}")
endforeach()
foreach(_name IN LISTS CEF_RESOURCE_FILES)
  # "locales" is a directory and cannot be installed as a file.
  if(NOT _name STREQUAL "locales")
    list(APPEND _cef_runtime_files "${CEF_RESOURCE_DIR}/${_name}")
  endif()
endforeach()

# List of absolute paths to libraries that should be bundled with the plugin.
set(${PROJECT_NAME}_bundled_libraries
  ${_cef_runtime_files}
  $<TARGET_FILE:${CEF_IMPL_NAME}>
  $<TARGET_FILE:${CEF_SUBPROCESS_NAME}>
  PARENT_SCOPE
)

# "locales" is the one piece install(FILES) cannot deploy, so it gets a dedicated
# target. It is a separate target rather than a POST_BUILD step on the host
# executable, because a plugin cannot attach custom commands to a target it does
# not own.
#
# CEF looks for the locale paks in "<resources directory>/locales", and the
# resources directory defaults to the directory of the host executable.
add_custom_target(${PROJECT_NAME}_cef_runtime ALL
  COMMAND ${CMAKE_COMMAND} -E copy_directory
          "${CEF_RESOURCE_DIR}/locales"
          "$<TARGET_FILE_DIR:${BINARY_NAME}>/locales"
  COMMENT "Deploying CEF locale resources"
  VERBATIM
)

# The destination directory only exists once the host executable has been linked.
add_dependencies(${PROJECT_NAME}_cef_runtime ${BINARY_NAME})
