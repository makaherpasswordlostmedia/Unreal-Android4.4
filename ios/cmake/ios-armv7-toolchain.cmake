# Toolchain: iOS armv7 (min iOS 7.0) cross-compiled from Linux.
# Needs: L1ghtmann LLVM iOS toolchain (Theos) + iPhoneOS 9.3 SDK.
#   IOS_TOOLCHAIN_BIN  = <theos>/toolchain/linux/iphone/bin   (or set THEOS)
#   IOS_SDK            = <theos>/sdks/iPhoneOS9.3.sdk          (or set THEOS)
# CMake's own iOS platform module needs an Apple SDK name (fails on Linux): use Darwin and flag IOS ourselves.
set(CMAKE_SYSTEM_NAME Darwin)
set(IOS TRUE)
set(CMAKE_SYSTEM_PROCESSOR armv7)
set(CMAKE_OSX_ARCHITECTURES armv7 CACHE STRING "" FORCE)

if(NOT IOS_TOOLCHAIN_BIN)
  if(DEFINED ENV{IOS_TOOLCHAIN_BIN})
    set(IOS_TOOLCHAIN_BIN $ENV{IOS_TOOLCHAIN_BIN})
  elseif(DEFINED ENV{THEOS})
    set(IOS_TOOLCHAIN_BIN $ENV{THEOS}/toolchain/linux/iphone/bin)
  endif()
endif()
if(NOT IOS_SDK)
  if(DEFINED ENV{IOS_SDK})
    set(IOS_SDK $ENV{IOS_SDK})
  elseif(DEFINED ENV{THEOS})
    set(IOS_SDK $ENV{THEOS}/sdks/iPhoneOS9.3.sdk)
  endif()
endif()
if(NOT IOS_TOOLCHAIN_BIN OR NOT IOS_SDK)
  message(FATAL_ERROR "Set THEOS, or IOS_TOOLCHAIN_BIN and IOS_SDK")
endif()

set(CMAKE_SYSROOT ${IOS_SDK})
set(CMAKE_OSX_SYSROOT ${IOS_SDK} CACHE PATH "" FORCE)
set(CMAKE_C_COMPILER   ${IOS_TOOLCHAIN_BIN}/clang)
set(CMAKE_CXX_COMPILER ${IOS_TOOLCHAIN_BIN}/clang++)
set(CMAKE_OBJC_COMPILER   ${IOS_TOOLCHAIN_BIN}/clang)
set(CMAKE_OBJCXX_COMPILER ${IOS_TOOLCHAIN_BIN}/clang++)
foreach(L C CXX OBJC OBJCXX)
  set(CMAKE_${L}_COMPILER_WORKS TRUE)
  set(CMAKE_${L}_COMPILER_TARGET armv7-apple-ios7.0)
endforeach()
find_program(IOS_AR     NAMES llvm-ar ar         HINTS ${IOS_TOOLCHAIN_BIN} NO_DEFAULT_PATH)
find_program(IOS_RANLIB NAMES llvm-ranlib ranlib HINTS ${IOS_TOOLCHAIN_BIN} NO_DEFAULT_PATH)
find_program(IOS_AR     NAMES llvm-ar ar)
find_program(IOS_RANLIB NAMES llvm-ranlib ranlib)
set(CMAKE_AR ${IOS_AR} CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB ${IOS_RANLIB} CACHE FILEPATH "" FORCE)

# Optional: ld64 (cctools-port / ld64.lld) if clang can't find the linker itself.
if(DEFINED ENV{IOS_LD})
  set(_ld "-fuse-ld=$ENV{IOS_LD}")
endif()

# 9.3 SDK module maps confuse modern clang.
set(_common "-arch armv7 -miphoneos-version-min=7.0 -isysroot ${IOS_SDK} -fno-modules -fno-implicit-modules -fno-implicit-module-maps -Wno-deprecated-declarations -Wno-error")
set(CMAKE_C_FLAGS_INIT   "${_common}")
# Toolchain's libc++ 19 headers lack __config_site; use the SDK's own libc++ headers (match the SDK's libc++.dylib).
set(_cxxinc "")
if(EXISTS ${IOS_SDK}/usr/include/c++/v1)
  set(_cxxinc "-nostdinc++ -isystem ${IOS_SDK}/usr/include/c++/v1")
endif()
set(CMAKE_CXX_FLAGS_INIT "${_common} -stdlib=libc++ ${_cxxinc}")
set(CMAKE_OBJC_FLAGS_INIT   "${_common}")
set(CMAKE_OBJCXX_FLAGS_INIT "${_common} -stdlib=libc++ ${_cxxinc}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-arch armv7 -miphoneos-version-min=7.0 -isysroot ${IOS_SDK} ${_ld}")
# Platform/Darwin.cmake forces libtool for static libs (absent on Linux) and overwrites anything set here,
# which made EVERY try_compile (check_function_exists, pthreads, ...) fail. A rules override is loaded after
# the platform module and is propagated into try_compile projects, so use plain ar+ranlib there.
set(CMAKE_USER_MAKE_RULES_OVERRIDE ${CMAKE_CURRENT_LIST_DIR}/ios-rules-override.cmake)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH ${IOS_SDK})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
