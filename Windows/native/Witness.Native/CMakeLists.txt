cmake_minimum_required(VERSION 3.28)

project(WitnessNative VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(WITNESS_ENABLE_VULKAN "Build the optional whisper.cpp Vulkan backend" OFF)
option(WITNESS_BUILD_TESTS "Build native contract tests" ON)

include(FetchContent)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN ${WITNESS_ENABLE_VULKAN} CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
  whisper_cpp
  GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp.git
  GIT_TAG 927cfce34f31707e17f2bff35c349632fb9e2c3a
  GIT_SHALLOW FALSE
  GIT_PROGRESS TRUE
)
FetchContent_MakeAvailable(whisper_cpp)

add_library(Witness.Native SHARED
  src/witness_native.cpp
  include/witness_native.h
)
target_include_directories(Witness.Native PUBLIC include)
target_link_libraries(Witness.Native PRIVATE whisper)
target_compile_definitions(Witness.Native PRIVATE WITNESS_NATIVE_BUILD=1)

if(MSVC)
  target_compile_options(Witness.Native PRIVATE /W4 /WX /permissive- /EHsc)
else()
  target_compile_options(Witness.Native PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

set_target_properties(Witness.Native PROPERTIES
  OUTPUT_NAME "Witness.Native"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
)

if(WITNESS_BUILD_TESTS)
  enable_testing()
  add_executable(witness_native_contract_tests tests/native_contract_tests.cpp)
  target_link_libraries(witness_native_contract_tests PRIVATE Witness.Native)
  set_target_properties(witness_native_contract_tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
  )
  add_test(NAME witness_native_contract_tests COMMAND witness_native_contract_tests)
  set_tests_properties(witness_native_contract_tests PROPERTIES TIMEOUT 30)

  # Invoked explicitly by CI after it creates a synthetic WAV and verifies the
  # pinned fixture-model hash. It is not registered with CTest because normal
  # source builds intentionally contain neither model weights nor audio files.
  add_executable(witness_native_inference_smoke tests/native_inference_smoke.cpp)
  target_link_libraries(witness_native_inference_smoke PRIVATE Witness.Native)
  set_target_properties(witness_native_inference_smoke PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
  )
endif()
