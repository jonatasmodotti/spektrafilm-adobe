set(SPEKTRAFILM_AE_SDK_ROOT "${PROJECT_SOURCE_DIR}/sdks/after-effects" CACHE PATH "After Effects C++ SDK")
set(SPEKTRAFILM_PR_SDK_ROOT "${PROJECT_SOURCE_DIR}/sdks/premiere" CACHE PATH "Premiere Pro C++ SDK")
if(NOT EXISTS "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Headers/AE_Effect.h")
  message(FATAL_ERROR "Set SPEKTRAFILM_AE_SDK_ROOT to the extracted After Effects C++ SDK.")
endif()
# PF_VERSION(major, minor, patch, PF_Stage_DEVELOP, 1): the PiPL's
# AE_Effect_Version and GLOBAL_SETUP's my_version must agree.
math(EXPR SPEKTRAFILM_PF_VERSION
  "(${PROJECT_VERSION_MAJOR} << 19) | (${PROJECT_VERSION_MINOR} << 15) | (${PROJECT_VERSION_PATCH} << 11) | 1")
add_library(spektrafilm_effect MODULE src/adobe/AdobeEffect.cpp src/adobe/AdobeBanner.cpp)
target_include_directories(spektrafilm_effect PRIVATE src src/adobe
  "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Headers"
  "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Headers/SP"
  "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Util")
target_compile_definitions(spektrafilm_effect PRIVATE PF_DEEP_COLOR_AWARE=1 NOMINMAX
  SPEKTRAFILM_VERSION="${PROJECT_VERSION}" SPEKTRAFILM_PF_VERSION=${SPEKTRAFILM_PF_VERSION}
  SPEKTRAFILM_SUPPORT_URL="https://github.com/jonatasmodotti/spektrafilm-adobe")
set_target_properties(spektrafilm_effect PROPERTIES PREFIX "" OUTPUT_NAME SpektraFilm)
file(GLOB LEGAL_FILES CONFIGURE_DEPENDS "${PROJECT_SOURCE_DIR}/Legal/*")
set_property(TARGET spektrafilm_effect APPEND PROPERTY LINK_DEPENDS
  "${PROJECT_SOURCE_DIR}/LICENSE" ${LEGAL_FILES})
if(APPLE)
  if(NOT EXISTS "${SPEKTRAFILM_PR_SDK_ROOT}/Examples/Headers/PrSDKGPUFilter.h")
    message(FATAL_ERROR "Set SPEKTRAFILM_PR_SDK_ROOT to the extracted Premiere C++ SDK.")
  endif()
  target_sources(spektrafilm_effect PRIVATE src/adobe/PremiereGpu.mm src/adobe/AdobeBannerMac.mm)
  target_compile_options(spektrafilm_effect PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
  target_include_directories(spektrafilm_effect PRIVATE "${SPEKTRAFILM_PR_SDK_ROOT}/Examples/Headers")
  target_link_libraries(spektrafilm_effect PRIVATE spektra_metal_bridge "-framework CoreGraphics" "-framework ImageIO")
  if(BUILD_TESTING)
    add_executable(adobe_effect_tests tests/AdobeEffectTests.mm)
    target_include_directories(adobe_effect_tests PRIVATE src
      "${SPEKTRAFILM_OFX_ROOT}/src" "${GENERATED}"
      "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Headers"
      "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Headers/SP"
      "${SPEKTRAFILM_PR_SDK_ROOT}/Examples/Headers")
    target_compile_definitions(adobe_effect_tests PRIVATE PF_DEEP_COLOR_AWARE=1)
    target_compile_options(adobe_effect_tests PRIVATE -fobjc-arc)
    target_link_libraries(adobe_effect_tests PRIVATE "-framework Foundation" "-framework Metal")
    add_dependencies(adobe_effect_tests spektrafilm_effect)
    add_test(NAME adobe_effect_abi COMMAND adobe_effect_tests "$<TARGET_FILE:spektrafilm_effect>")
    set_tests_properties(adobe_effect_abi PROPERTIES LABELS "gpu" SKIP_RETURN_CODE 77)
  endif()
  set_target_properties(spektrafilm_effect PROPERTIES BUNDLE TRUE BUNDLE_EXTENSION plugin
    MACOSX_BUNDLE_INFO_PLIST "${PROJECT_SOURCE_DIR}/cmake/Info.plist.in"
    LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/plugin")
  find_program(REZ_EXECUTABLE Rez REQUIRED)
  set(PIPL "${PROJECT_BINARY_DIR}/SpektraFilm.rsrc")
  add_custom_command(OUTPUT "${PIPL}"
    COMMAND "${REZ_EXECUTABLE}" -useDF -d SPEKTRAFILM_PF_VERSION=${SPEKTRAFILM_PF_VERSION}
      -i "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Headers"
      -i "${SPEKTRAFILM_AE_SDK_ROOT}/Examples/Resources"
      "${PROJECT_SOURCE_DIR}/src/adobe/SpektraFilmPiPL.r" -o "${PIPL}"
    DEPENDS src/adobe/SpektraFilmPiPL.r "${PROJECT_SOURCE_DIR}/CMakeLists.txt" VERBATIM)
  add_custom_target(spektra_pipl DEPENDS "${PIPL}")
  add_dependencies(spektrafilm_effect spektra_pipl)
  configure_file(cmake/Info.plist.in "${PROJECT_BINARY_DIR}/SpektraFilm-Info.plist" @ONLY)
  set_property(TARGET spektrafilm_effect APPEND PROPERTY LINK_DEPENDS
    "${PIPL}" "${PROJECT_BINARY_DIR}/SpektraFilm-Info.plist")
  add_custom_command(TARGET spektrafilm_effect POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${RESOURCES}" "$<TARGET_BUNDLE_CONTENT_DIR:spektrafilm_effect>/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy "${PIPL}" "$<TARGET_BUNDLE_CONTENT_DIR:spektrafilm_effect>/Resources/SpektraFilm.rsrc"
    COMMAND "${CMAKE_COMMAND}" -E copy "${PROJECT_SOURCE_DIR}/assets/banner.jpg" "$<TARGET_BUNDLE_CONTENT_DIR:spektrafilm_effect>/Resources/banner.jpg"
    COMMAND "${CMAKE_COMMAND}" -E copy "${PROJECT_SOURCE_DIR}/LICENSE" "$<TARGET_BUNDLE_CONTENT_DIR:spektrafilm_effect>/Resources/LICENSE"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${PROJECT_SOURCE_DIR}/Legal" "$<TARGET_BUNDLE_CONTENT_DIR:spektrafilm_effect>/Resources/Legal"
    COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:spektrafilm_effect>"
    VERBATIM)
else()
  if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR CMAKE_SYSTEM_PROCESSOR MATCHES "ARM|arm")
    message(FATAL_ERROR "The Windows development build requires MSVC x64 and the Vulkan SDK.")
  endif()
  enable_language(RC)
  target_sources(spektrafilm_effect PRIVATE src/adobe/AdobeBannerWin.cpp)
  target_link_libraries(spektrafilm_effect PRIVATE spektra_native windowscodecs ole32)
  set(PIPL_RC "${PROJECT_BINARY_DIR}/generated/SpektraFilmPiPL.rc")
  add_custom_command(OUTPUT "${PIPL_RC}"
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tools/build_pipl_windows.py"
      --compiler "${CMAKE_CXX_COMPILER}" --sdk "${SPEKTRAFILM_AE_SDK_ROOT}"
      --source "${PROJECT_SOURCE_DIR}/src/adobe/SpektraFilmPiPL.r" --output "${PIPL_RC}"
      --define "SPEKTRAFILM_PF_VERSION=${SPEKTRAFILM_PF_VERSION}"
    DEPENDS src/adobe/SpektraFilmPiPL.r tools/build_pipl_windows.py "${PROJECT_SOURCE_DIR}/CMakeLists.txt" VERBATIM)
  target_sources(spektrafilm_effect PRIVATE "${PIPL_RC}")
  set_target_properties(spektrafilm_effect PROPERTIES SUFFIX ".aex"
    RUNTIME_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/plugin/SpektraFilm/Contents/Win64"
    LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/plugin/SpektraFilm/Contents/Win64")
  foreach(CONFIG DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(spektrafilm_effect PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY_${CONFIG} "${PROJECT_BINARY_DIR}/plugin/SpektraFilm/Contents/Win64"
      LIBRARY_OUTPUT_DIRECTORY_${CONFIG} "${PROJECT_BINARY_DIR}/plugin/SpektraFilm/Contents/Win64")
  endforeach()
  add_custom_command(TARGET spektrafilm_effect POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${RESOURCES}" "$<TARGET_FILE_DIR:spektrafilm_effect>/../Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy "${PROJECT_SOURCE_DIR}/assets/banner.jpg" "$<TARGET_FILE_DIR:spektrafilm_effect>/../Resources/banner.jpg"
    COMMAND "${CMAKE_COMMAND}" -E copy "${PROJECT_SOURCE_DIR}/LICENSE" "$<TARGET_FILE_DIR:spektrafilm_effect>/../Resources/LICENSE"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${PROJECT_SOURCE_DIR}/Legal" "$<TARGET_FILE_DIR:spektrafilm_effect>/../Resources/Legal"
    VERBATIM)
endif()
