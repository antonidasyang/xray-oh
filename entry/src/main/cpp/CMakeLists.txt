# libxraybridge.so: the NAPI module ArkTS imports. It links libxray.so, the Go
# build of Xray-core in entry/libs/<abi>/, from where hvigor packages it into
# the HAP next to this library.
cmake_minimum_required(VERSION 3.16)
project(xraybridge CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The OHOS toolchain file passes --gcc-toolchain, which clang does not use.
add_compile_options(-Wno-unused-command-line-argument)

# Prebuilt libxray.so published with the release below. A library built
# locally with scripts/build_libxray.sh takes its place and is used as is.
set(LIBXRAY_RELEASE v0.1.0)
set(LIBXRAY_SHA256 fcfd103fdb53a45eb0a4a6e65992d7cec5c638d66d417badae48409796acabc2)
set(LIBXRAY_URL https://github.com/antonidasyang/xray-oh/releases/download/${LIBXRAY_RELEASE}/libxray.so)

set(XRAY_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libxray.so)
if(NOT EXISTS ${XRAY_LIB})
    if(NOT OHOS_ARCH STREQUAL "arm64-v8a")
        message(FATAL_ERROR "libxray.so is only published for arm64-v8a; build it with scripts/build_libxray.sh")
    endif()
    message(STATUS "Downloading ${LIBXRAY_URL}")
    file(DOWNLOAD ${LIBXRAY_URL} ${XRAY_LIB}.part
         EXPECTED_HASH SHA256=${LIBXRAY_SHA256} TLS_VERIFY ON STATUS LIBXRAY_STATUS)
    list(GET LIBXRAY_STATUS 0 LIBXRAY_CODE)
    if(NOT LIBXRAY_CODE EQUAL 0)
        file(REMOVE ${XRAY_LIB}.part)
        message(FATAL_ERROR "Could not download libxray.so (${LIBXRAY_STATUS}). "
                            "Download ${LIBXRAY_URL} to ${XRAY_LIB} or run scripts/build_libxray.sh.")
    endif()
    file(RENAME ${XRAY_LIB}.part ${XRAY_LIB})
endif()

add_library(xray SHARED IMPORTED)
set_target_properties(xray PROPERTIES IMPORTED_LOCATION ${XRAY_LIB} IMPORTED_NO_SONAME OFF)

add_library(xraybridge SHARED napi_init.cpp)
target_include_directories(xraybridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(xraybridge PRIVATE xray libace_napi.z.so libhilog_ndk.z.so)
