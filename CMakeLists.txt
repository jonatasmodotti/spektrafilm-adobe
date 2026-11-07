cmake_minimum_required(VERSION 3.24)
project(SpektraFilmAdobe VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
include(CTest)

add_library(spektra_frame_layout STATIC src/FrameLayout.cpp)
target_include_directories(spektra_frame_layout PUBLIC include)
if(BUILD_TESTING)
  add_executable(frame_layout_tests tests/FrameLayoutTests.cpp)
  target_link_libraries(frame_layout_tests PRIVATE spektra_frame_layout)
  add_test(NAME frame_layout COMMAND frame_layout_tests)
endif()

option(SPEKTRAFILM_BUILD_METAL "Build the native Metal renderer and Adobe buffer bridge" ${APPLE})
option(SPEKTRAFILM_BUILD_VULKAN "Build the Windows native Vulkan renderer with host-memory frames" ${WIN32})
set(SPEKTRAFILM_OFX_ROOT "${PROJECT_SOURCE_DIR}/third_party/spektrafilm-ofx" CACHE PATH "Pinned upstream checkout")
set(SPEKTRAFILM_REFERENCE_ROOT "${PROJECT_SOURCE_DIR}/third_party/spektrafilm" CACHE PATH "Pinned spektrafilm model data checkout")
# reference: spektrafilm at the reference commit in upstream.lock.json (profiles,
#   neutral print filters, CAT16 input adaptation, input gamut compression).
# ofx: the model spektrafilm-ofx ships, spektrafilm c4f2d23.
set(SPEKTRAFILM_MODEL "reference" CACHE STRING "Film model generation: reference or ofx")
set_property(CACHE SPEKTRAFILM_MODEL PROPERTY STRINGS reference ofx)
if(SPEKTRAFILM_BUILD_METAL OR SPEKTRAFILM_BUILD_VULKAN)
  if(SPEKTRAFILM_BUILD_METAL AND SPEKTRAFILM_BUILD_VULKAN)
    message(FATAL_ERROR "Select one native GPU backend for this platform.")
  endif()
  if(NOT EXISTS "${SPEKTRAFILM_OFX_ROOT}/src/SpektraMetalRenderer.mm")
    message(FATAL_ERROR "Run python tools/bootstrap.py before configuring the native build.")
  endif()
  if(SPEKTRAFILM_BUILD_METAL)
    if(NOT APPLE)
      message(FATAL_ERROR "Metal requires macOS.")
    endif()
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 17)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
  endif()
  if(WIN32 AND NOT DEFINED Python3_EXECUTABLE AND EXISTS "${PROJECT_SOURCE_DIR}/.venv/Scripts/python.exe")
    set(Python3_EXECUTABLE "${PROJECT_SOURCE_DIR}/.venv/Scripts/python.exe")
  endif()
  if(NOT DEFINED Python3_EXECUTABLE AND EXISTS "${PROJECT_SOURCE_DIR}/.venv/bin/python")
    set(Python3_EXECUTABLE "${PROJECT_SOURCE_DIR}/.venv/bin/python")
  endif()
  file(READ "${PROJECT_SOURCE_DIR}/upstream.lock.json" UPSTREAM_LOCK)
  string(JSON PINNED_OFX_COMMIT GET "${UPSTREAM_LOCK}" ofx commit)
  execute_process(COMMAND git rev-parse HEAD WORKING_DIRECTORY "${SPEKTRAFILM_OFX_ROOT}"
    OUTPUT_VARIABLE CHECKOUT_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  if(NOT CHECKOUT_COMMIT STREQUAL PINNED_OFX_COMMIT)
    message(FATAL_ERROR "The upstream checkout does not match upstream.lock.json.")
  endif()
  set(MODEL_ENV "SPEKTRAFILM_MODEL=${SPEKTRAFILM_MODEL}")
  if(SPEKTRAFILM_MODEL STREQUAL "reference")
    string(JSON PINNED_REFERENCE_COMMIT GET "${UPSTREAM_LOCK}" reference commit)
    execute_process(COMMAND git rev-parse HEAD WORKING_DIRECTORY "${SPEKTRAFILM_REFERENCE_ROOT}"
      OUTPUT_VARIABLE REFERENCE_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET RESULT_VARIABLE REFERENCE_RESULT)
    if(NOT REFERENCE_RESULT EQUAL 0 OR NOT REFERENCE_COMMIT STREQUAL PINNED_REFERENCE_COMMIT)
      message(FATAL_ERROR "The spektrafilm model data does not match upstream.lock.json. Run python3 tools/bootstrap.py.")
    endif()
    set(REFERENCE_DATA "${SPEKTRAFILM_REFERENCE_ROOT}/src/spektrafilm/data")
    list(APPEND MODEL_ENV
      "SPEKTRAFILM_PROFILE_DIR=${REFERENCE_DATA}/profiles"
      "SPEKTRAFILM_NEUTRAL_PRINT_FILTERS=${REFERENCE_DATA}/filters/neutral_print_filters.json")
  elseif(NOT SPEKTRAFILM_MODEL STREQUAL "ofx")
    message(FATAL_ERROR "SPEKTRAFILM_MODEL must be reference or ofx.")
  endif()
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  execute_process(COMMAND "${Python3_EXECUTABLE}" -c "import numpy, scipy, colour"
    RESULT_VARIABLE DEPS_RESULT ERROR_VARIABLE DEPS_ERROR)
  if(NOT DEPS_RESULT EQUAL 0)
    message(FATAL_ERROR "Install requirements-build.txt into ${Python3_EXECUTABLE}: ${DEPS_ERROR}")
  endif()
  execute_process(COMMAND git apply --reverse --check "${PROJECT_SOURCE_DIR}/patches/adobe-port.patch"
    WORKING_DIRECTORY "${SPEKTRAFILM_OFX_ROOT}" RESULT_VARIABLE PATCH_RESULT OUTPUT_QUIET ERROR_QUIET)
  if(NOT PATCH_RESULT EQUAL 0)
    message(FATAL_ERROR "The native port patch is missing. Run python3 tools/bootstrap.py.")
  endif()

  set(GENERATED "${PROJECT_BINARY_DIR}/generated")
  set(RESOURCES "${PROJECT_BINARY_DIR}/resources")
  file(MAKE_DIRECTORY "${GENERATED}" "${RESOURCES}")
  if(SPEKTRAFILM_BUILD_METAL)
    file(READ "${SPEKTRAFILM_OFX_ROOT}/shaders/SpektraFilm.metal" SPEKTRA_FILM_SOURCE)
    configure_file(cmake/SpektraFilmSource.h.in "${GENERATED}/SpektraFilmSource.h" @ONLY)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
      "${SPEKTRAFILM_OFX_ROOT}/shaders/SpektraFilm.metal")
  endif()

  file(GLOB_RECURSE TABLE_INPUTS CONFIGURE_DEPENDS "${SPEKTRAFILM_OFX_ROOT}/Resources/data/*")
  # Regenerates the tables when the model changes; CONFIGURE rewrites it only then.
  file(CONFIGURE OUTPUT "${GENERATED}/SpektraModel.txt" CONTENT "${SPEKTRAFILM_MODEL}\n")
  list(APPEND TABLE_INPUTS "${GENERATED}/SpektraModel.txt")
  if(SPEKTRAFILM_MODEL STREQUAL "reference")
    file(GLOB_RECURSE REFERENCE_INPUTS CONFIGURE_DEPENDS "${REFERENCE_DATA}/*")
    list(APPEND TABLE_INPUTS ${REFERENCE_INPUTS})
  endif()
  set(TABLES "${GENERATED}/SpektraGeneratedProfileCurves.cpp")
  set(COUNTS "${GENERATED}/SpektraGeneratedProfileCounts.h")
  set(HANATOS "${RESOURCES}/SpektraHanatos2025Spectra.f32")
  set(GAMUT "${RESOURCES}/SpektraOutputGamutCompression.f32")
  add_custom_command(OUTPUT "${TABLES}" "${COUNTS}" "${HANATOS}" "${GAMUT}"
    COMMAND "${CMAKE_COMMAND}" -E env
      "SPEKTRAFILM_DATA_DIR=${SPEKTRAFILM_OFX_ROOT}/Resources/data"
      "MPLCONFIGDIR=${PROJECT_BINARY_DIR}/cache/matplotlib"
      "XDG_CACHE_HOME=${PROJECT_BINARY_DIR}/cache"
      ${MODEL_ENV}
      "${Python3_EXECUTABLE}" "${SPEKTRAFILM_OFX_ROOT}/tools/generate_profile_curves.py"
      --output "${TABLES}" --counts-output "${COUNTS}"
      --hanatos-output "${HANATOS}" --output-gamut-compression-output "${GAMUT}"
    DEPENDS ${TABLE_INPUTS}
      "${SPEKTRAFILM_OFX_ROOT}/tools/generate_profile_curves.py"
      "${SPEKTRAFILM_OFX_ROOT}/tools/ofx_stock_lists.py"
    VERBATIM)
  add_library(spektra_native STATIC "${TABLES}" "${COUNTS}")
  target_include_directories(spektra_native PUBLIC "${SPEKTRAFILM_OFX_ROOT}/src" "${GENERATED}")
  if(SPEKTRAFILM_BUILD_VULKAN)
    find_package(Vulkan REQUIRED)
    find_program(GLSLC_EXECUTABLE glslc HINTS "$ENV{VULKAN_SDK}/Bin" "$ENV{VULKAN_SDK}/bin" REQUIRED)
    target_sources(spektra_native PRIVATE "${SPEKTRAFILM_OFX_ROOT}/src/SpektraVulkanRenderer.cpp")
    target_link_libraries(spektra_native PUBLIC Vulkan::Vulkan)
    target_compile_definitions(spektra_native PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    set(VULKAN_BINARIES)
    foreach(SHADER Copy FormatConvert FilmExposure CurveDevelop PrintScan Halation Diffusion Dir ScannerPost Grain)
      set(INPUT_SHADER "${SPEKTRAFILM_OFX_ROOT}/shaders/vulkan/Spektra${SHADER}.comp")
      set(OUTPUT_SHADER "${RESOURCES}/shaders/Spektra${SHADER}.comp.spv")
      add_custom_command(OUTPUT "${OUTPUT_SHADER}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${RESOURCES}/shaders"
        COMMAND "${GLSLC_EXECUTABLE}" -fshader-stage=compute "${INPUT_SHADER}" -o "${OUTPUT_SHADER}"
        DEPENDS "${INPUT_SHADER}" VERBATIM)
      list(APPEND VULKAN_BINARIES "${OUTPUT_SHADER}")
    endforeach()
    add_custom_target(spektra_vulkan_shaders DEPENDS ${VULKAN_BINARIES})
    add_dependencies(spektra_native spektra_vulkan_shaders)
  else()
    target_sources(spektra_native PRIVATE "${SPEKTRAFILM_OFX_ROOT}/src/SpektraMetalRenderer.mm")
    target_compile_definitions(spektra_native PRIVATE SPEKTRAFILM_ADOBE_PORT=1)
    target_compile_options(spektra_native PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_link_libraries(spektra_native PUBLIC "-framework Foundation" "-framework Metal" "-framework MetalPerformanceShaders")
  endif()

  if(SPEKTRAFILM_BUILD_METAL)
  add_library(spektra_metal_bridge STATIC src/metal/MetalBridge.mm)
  target_compile_options(spektra_metal_bridge PRIVATE -fobjc-arc)
  target_link_libraries(spektra_metal_bridge PUBLIC spektra_native spektra_frame_layout)
  add_executable(metal_benchmark tools/MetalBenchmark.mm)
  target_compile_options(metal_benchmark PRIVATE -fobjc-arc)
  target_link_libraries(metal_benchmark PRIVATE spektra_metal_bridge)
  if(BUILD_TESTING)
    add_executable(metal_bridge_tests tests/MetalBridgeTests.mm)
    target_include_directories(metal_bridge_tests PRIVATE src)
    target_compile_options(metal_bridge_tests PRIVATE -fobjc-arc)
    target_link_libraries(metal_bridge_tests PRIVATE spektra_metal_bridge)
    add_test(NAME metal_bridge COMMAND metal_bridge_tests)
    # Upstream Python-vs-Metal parity harness, run against this port's renderer
    # (patch and optimizations included). Procedure and results: docs/PARITY.md.
    add_executable(spektra_parity_harness "${SPEKTRAFILM_OFX_ROOT}/tools/SpektraMetalParityHarness.mm")
    target_include_directories(spektra_parity_harness PRIVATE "${SPEKTRAFILM_OFX_ROOT}/tools")
    target_compile_options(spektra_parity_harness PRIVATE -fobjc-arc)
    target_link_libraries(spektra_parity_harness PRIVATE spektra_native)
    set_tests_properties(metal_bridge PROPERTIES
      ENVIRONMENT "SPEKTRAFILM_RESOURCE_DIR=${RESOURCES}" LABELS "gpu" SKIP_RETURN_CODE 77)
  endif()
  endif()
endif()

option(SPEKTRAFILM_BUILD_ADOBE_PLUGIN "Build the native Adobe effect" OFF)
if(SPEKTRAFILM_BUILD_ADOBE_PLUGIN)
  if(NOT TARGET spektra_native)
    message(FATAL_ERROR "Enable the native renderer to build the Adobe plugin.")
  endif()
  include(cmake/AdobePlugin.cmake)
endif()
