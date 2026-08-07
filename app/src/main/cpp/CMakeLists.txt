cmake_minimum_required(VERSION 3.22)
project("agora_llama" LANGUAGES C CXX)

set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../thirdparty/llama.cpp" CACHE PATH "llama.cpp source directory")
get_filename_component(LLAMA_CPP_DIR "${LLAMA_CPP_DIR}" REALPATH)

add_compile_options(
    -ffile-prefix-map=${CMAKE_SOURCE_DIR}=.
    -ffile-prefix-map=${LLAMA_CPP_DIR}=llama.cpp
    -g0
    -fno-ident
)

set(LLAMA_BUILD_NUMBER 0)
set(LLAMA_BUILD_COMMIT "unknown")
set(LLAMA_INSTALL_VERSION "0.0.0")
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "")
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "")
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "")
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

# ── armeabi-v7a: pin a safe, NEON-optional baseline ──────────────────
# 32-bit ARM devices vary widely in feature support. GGML_NATIVE is already
# OFF for this cross-compile (ggml disables it automatically when
# CMAKE_CROSSCOMPILING is set), so ggml falls into its GGML_CPU_ARM_ARCH /
# GGML_CPU_ALL_VARIANTS branch (see ggml/src/ggml-cpu/CMakeLists.txt). We set
# GGML_CPU_ARM_ARCH explicitly to a conservative "armv7-a" baseline so the
# build never assumes dotprod/i8mm/SVE (all AArch64-only or high-end-only
# extensions) on a 32-bit target. Correctness over peak performance.
if(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(GGML_CPU_ARM_ARCH "armv7-a" CACHE STRING "" FORCE)
    message(STATUS "armeabi-v7a: pinning GGML_CPU_ARM_ARCH=armv7-a (no dotprod/i8mm/SVE assumptions)")

    # ggml's optional "llamafile" SGEMM fast-path (ggml-cpu/llamafile/sgemm.cpp) has an
    # upstream bug on 32-bit ARM: its `#if defined(__ARM_NEON)` guard around
    # vld1q_f16/vld1_f16 doesn't also check __ARM_FEATURE_FP16_VECTOR_ARITHMETIC (there's a
    # FIXME comment acknowledging this in the source), so it fails to compile with
    # "use of undeclared identifier 'vld1q_f16'" on armv7-a NEON, which lacks the ARMv8.2
    # FP16 arithmetic extension that AArch64 has. It's a pure performance optimization —
    # disabling it just makes ggml use its normal (still NEON-accelerated where safe)
    # matmul path. Correctness over performance on 32-bit ARM.
    set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
    message(STATUS "armeabi-v7a: disabling GGML_LLAMAFILE (upstream FP16-guard bug on 32-bit ARM NEON)")
endif()

add_subdirectory(${LLAMA_CPP_DIR} ${CMAKE_CURRENT_BINARY_DIR}/llama)
add_subdirectory(${LLAMA_CPP_DIR}/common ${CMAKE_CURRENT_BINARY_DIR}/common)
add_subdirectory(${LLAMA_CPP_DIR}/tools/mtmd ${CMAKE_CURRENT_BINARY_DIR}/mtmd)

foreach(cli llama-mtmd-cli llama-mtmd-debug
         llama-llava-cli llama-gemma3-cli llama-minicpmv-cli llama-qwen2vl-cli)
    if(TARGET ${cli})
        set_target_properties(${cli} PROPERTIES EXCLUDE_FROM_ALL TRUE)
    endif()
endforeach()
foreach(cli llama-llava-cli llama-gemma3-cli llama-minicpmv-cli llama-qwen2vl-cli)
    if(TARGET ${cli})
        target_include_directories(${cli} PRIVATE ${LLAMA_CPP_DIR}/common)
    endif()
endforeach()
if(TARGET llama-mtmd-cli)
    target_include_directories(llama-mtmd-cli PRIVATE ${LLAMA_CPP_DIR}/common ${LLAMA_CPP_DIR}/vendor)
endif()
if(TARGET llama-mtmd-debug)
    target_include_directories(llama-mtmd-debug PRIVATE ${LLAMA_CPP_DIR}/common ${LLAMA_CPP_DIR}/vendor)
endif()

target_compile_definitions(ggml-base PRIVATE GGML_COMMIT="unknown")

# Build llama JNI wrapper
add_library(agora_llama SHARED llama_jni.cpp llama_chat_jni.cpp)
target_link_libraries(agora_llama llama mtmd log)
target_include_directories(agora_llama PRIVATE ${LLAMA_CPP_DIR}/include ${LLAMA_CPP_DIR}/tools/mtmd)
target_link_options(agora_llama PRIVATE
    -Wl,--build-id=none -Wl,--hash-style=gnu -Wl,--icf=all -Wl,--threads=1
)

# ── objcopy for reproducible builds ──────────────────────
find_program(LLVM_OBJCOPY llvm-objcopy
    HINTS ${ANDROID_NDK}/toolchains/llvm/prebuilt/*/bin NO_DEFAULT_PATH
)

# ── Minimal JNI stub for proot ───────────────────────────
# System.loadLibrary("agora_proot") triggers APK extraction of native libs.
# Actual proot execution uses ProcessBuilder on libproot_exec.so (GNUmakefile-built).
add_library(agora_proot SHARED proot_jni.cpp)
target_link_options(agora_proot PRIVATE
    -Wl,--build-id=none -Wl,--hash-style=gnu -Wl,--icf=all
)

# ── Reproducible: strip .comment ─────────────────────────
if(DEFINED ENV{SOURCE_DATE_EPOCH})
    add_definitions(-DSOURCE_DATE_EPOCH=$ENV{SOURCE_DATE_EPOCH})
endif()
if(LLVM_OBJCOPY)
    add_custom_command(TARGET agora_llama POST_BUILD
        COMMAND ${LLVM_OBJCOPY} --remove-section .comment $<TARGET_FILE:agora_llama>
    )
    add_custom_command(TARGET agora_proot POST_BUILD
        COMMAND ${LLVM_OBJCOPY} --remove-section .comment $<TARGET_FILE:agora_proot>
    )
endif()
