# libxraybridge.so: the NAPI module ArkTS imports. It links libxray.so, the Go
# build of Xray-core produced by scripts/build_libxray.sh into entry/libs/<abi>/,
# from where hvigor packages it into the HAP next to this library.
cmake_minimum_required(VERSION 3.16)
project(xraybridge CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The OHOS toolchain file passes --gcc-toolchain, which clang does not use.
add_compile_options(-Wno-unused-command-line-argument)

set(XRAY_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libxray.so)
if(NOT EXISTS ${XRAY_LIB})
    message(FATAL_ERROR "${XRAY_LIB} is missing. Run scripts/build_libxray.sh first.")
endif()

add_library(xray SHARED IMPORTED)
set_target_properties(xray PROPERTIES IMPORTED_LOCATION ${XRAY_LIB} IMPORTED_NO_SONAME OFF)

add_library(xraybridge SHARED napi_init.cpp)
target_include_directories(xraybridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(xraybridge PRIVATE xray libace_napi.z.so libhilog_ndk.z.so)
