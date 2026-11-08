cmake_minimum_required(VERSION 3.20)
project(UnrealiOS C CXX OBJC OBJCXX)

# Static libs via plain ar+ranlib (no libtool/Apple tools on Linux)
foreach(L C CXX OBJC OBJCXX)
  set(CMAKE_${L}_CREATE_STATIC_LIBRARY "<CMAKE_AR> qc <TARGET> <LINK_FLAGS> <OBJECTS>" "<CMAKE_RANLIB> <TARGET>")
endforeach()

set(CMAKE_POSITION_INDEPENDENT_CODE OFF)
set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "")

# ---- SDL2 (UIKit, static, GLES only)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON  CACHE BOOL "" FORCE)
set(SDL_TEST   OFF CACHE BOOL "" FORCE)
set(SDL_TESTS  OFF CACHE BOOL "" FORCE)
set(SDL_METAL  OFF CACHE BOOL "" FORCE)
set(SDL_RENDER_METAL OFF CACHE BOOL "" FORCE)
set(SDL_VULKAN OFF CACHE BOOL "" FORCE)
set(SDL_AUDIO  OFF CACHE BOOL "" FORCE)
set(SDL_HAPTIC OFF CACHE BOOL "" FORCE)
set(SDL_HIDAPI OFF CACHE BOOL "" FORCE)
set(SDL_OPENGLES ON CACHE BOOL "" FORCE)
add_subdirectory(third_party/SDL2 EXCLUDE_FROM_ALL)

# Expose headers as <SDL2/SDL.h>
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/sdlinc)
file(CREATE_LINK ${CMAKE_SOURCE_DIR}/third_party/SDL2/include ${CMAKE_BINARY_DIR}/sdlinc/SDL2 SYMBOLIC)
set(SDL2_INCLUDE_DIR "${CMAKE_BINARY_DIR}/sdlinc;${CMAKE_SOURCE_DIR}/third_party/SDL2/include" CACHE STRING "" FORCE)
set(SDL2_LIBRARY SDL2-static CACHE STRING "" FORCE)

# ---- libxmp
set(BUILD_STATIC ON CACHE BOOL "" FORCE)
set(BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(BUILD_LITE OFF CACHE BOOL "" FORCE)
set(WITH_UNIT_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/libxmp EXCLUDE_FROM_ALL)
set(LIBXMP_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/third_party/libxmp/include CACHE STRING "" FORCE)
set(LIBXMP_LIBRARY xmp_static CACHE STRING "" FORCE)

# ---- OpenAL (Apple framework + shim headers for EFX/SOFT extensions)
set(OPENAL_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/ios/shim CACHE STRING "" FORCE)
set(OPENAL_LIBRARY "-framework OpenAL" CACHE STRING "" FORCE)

# ---- UE1
set(USE_SDL ON CACHE BOOL "" FORCE)
set(BUILD_EDITOR OFF CACHE BOOL "" FORCE)
set(BUILD_SOFTDRV OFF CACHE BOOL "" FORCE)
set(BUILD_NOPENGLDRV OFF CACHE BOOL "" FORCE)
set(BUILD_WINDRV OFF CACHE BOOL "" FORCE)
set(BUILD_NOPENGLESDRV ON CACHE BOOL "" FORCE)
set(BUILD_NOPENALDRV ON CACHE BOOL "" FORCE)
set(BUILD_NULLSOUNDDRV ON CACHE BOOL "" FORCE)
add_subdirectory(engine/Source ue1)

# ---- Host app
add_executable(UnrealiOS
  ios/host/UE1IOSHost.mm
  ios/host/ios_diag.mm
  ios/host/ios_availability_stub.m)
set_source_files_properties(ios/host/UE1IOSHost.mm ios/host/ios_diag.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(UnrealiOS PRIVATE ${SDL2_INCLUDE_DIR})

# UE1 packages register themselves via static initializers -> force_load each.
set(UE1_LIBS Core Engine Render IpDrv Fire NSDLDrv NOpenGLESDrv NOpenALDrv SoundDrv Unreal)
set(_fl "")
foreach(t ${UE1_LIBS})
  if(TARGET ${t})
    add_dependencies(UnrealiOS ${t})
    list(APPEND _fl "-Wl,-force_load,$<TARGET_FILE:${t}>")
  endif()
endforeach()
target_link_libraries(UnrealiOS PRIVATE ${_fl} SDL2main SDL2-static xmp_static
  "-framework UIKit" "-framework Foundation" "-framework OpenGLES" "-framework OpenAL"
  "-framework QuartzCore" "-framework CoreGraphics" "-framework AudioToolbox"
  "-framework CoreAudio" "-framework CoreMotion" "-framework CoreFoundation"
  "-framework AVFoundation" "-framework CoreVideo" "-weak_framework GameController"
  "-Wl,-dead_strip" c++)
set_target_properties(UnrealiOS PROPERTIES OUTPUT_NAME UnrealiOS)
