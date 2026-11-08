project(Unreal)

if(USE_SDL)
  set(SRC_FILES "Src/SDLLaunch.cpp")
else()
  set(SRC_FILES "Src/WinLaunch.cpp")
endif()

# NOTE: the upstream Android port repeated its "if(ANDROID)" block ~60 times here
# (an artefact of re-applying a patch script). This file was rewritten cleanly for iOS.

if(IOS)
  # iOS cannot dlopen() anything outside the bundle and a bare executable is
  # produced by the top-level CMakeLists, so the launcher is a static library.
  add_library(${PROJECT_NAME} STATIC ${SRC_FILES})
elseif(ANDROID)
  add_library(${PROJECT_NAME} SHARED ${SRC_FILES})
elseif(TARGET_IS_WINDOWS)
  list(APPEND SRC_FILES "Src/Res/LaunchRes.rc")
  add_executable(${PROJECT_NAME} WIN32 ${SRC_FILES})
else()
  add_executable(${PROJECT_NAME} ${SRC_FILES})
endif()

target_include_directories(${PROJECT_NAME}
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/Inc
  PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/Src
)

if(USE_SDL)
  target_include_directories(${PROJECT_NAME} PRIVATE ${SDL2_INCLUDE_DIR})
  if(NOT IOS)
    if(ANDROID AND BUILD_STATIC)
      target_link_libraries(${PROJECT_NAME} ${SDL2_LIBRARY})
    else()
      target_link_libraries(${PROJECT_NAME} ${SDL2_LIBRARY} NSDLDrv)
    endif()
  endif()
elseif(TARGET_IS_WINDOWS)
  target_link_libraries(${PROJECT_NAME} Window)
else()
  message(FATAL_ERROR "Non-Windows platforms can only use NSDLDrv.")
endif()

# iOS links every UE1 package with -force_load from the top-level CMakeLists
# (Apple ld64 has no --whole-archive); package registration happens in static
# initialisers, so they must not be dead-stripped.
if(NOT IOS)
  if(BUILD_STATIC)
    set(LINK_PACKAGES ${INSTALL_TARGETS})
    list(REMOVE_ITEM LINK_PACKAGES ${PROJECT_NAME})
    target_link_libraries(${PROJECT_NAME} -Wl,--whole-archive ${LINK_PACKAGES} -Wl,--no-whole-archive)
  else()
    target_link_libraries(${PROJECT_NAME} Engine Core)
  endif()
endif()

target_compile_definitions(${PROJECT_NAME} PRIVATE UNREAL_EXPORTS UPACKAGE_NAME=${PROJECT_NAME})

if(ANDROID)
  target_link_libraries(${PROJECT_NAME} android log GLESv2 EGL)
  target_compile_definitions(${PROJECT_NAME} PRIVATE PLATFORM_ANDROID UNREAL_ANDROID)
endif()

if(IOS)
  target_link_libraries(${PROJECT_NAME} PUBLIC Engine Core)
endif()
