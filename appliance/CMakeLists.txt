cmake_minimum_required(VERSION 3.22)
project(AutoMixAppliance VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# 1) DSP core unit tests — pure C++17, NO JUCE. This is the part that is
#    verified in CI and on this machine (clang++/g++). Build & run with:
#       cmake -B build -DBUILD_APP=OFF && cmake --build build && ctest --test-dir build
#    or directly:
#       clang++ -std=c++17 -O2 tests/test_dsp.cpp -o test_dsp && ./test_dsp
# ---------------------------------------------------------------------------
enable_testing()
add_executable(dsp_tests tests/test_dsp.cpp)
target_include_directories(dsp_tests PRIVATE dsp)
add_test(NAME dsp_tests COMMAND dsp_tests)

# Deterministic recorded-service replay/evaluation. This target has no JUCE or audio
# device dependency and is exercised in CI through its synthetic self-test.
add_executable(automix_replay tools/replay_eval.cpp)
target_include_directories(automix_replay PRIVATE dsp src tools)
add_test(NAME replay_eval_self_test COMMAND automix_replay --self-test)

# ---------------------------------------------------------------------------
# 2) The appliance: a headless standalone JUCE console app that opens the Dante
#    audio device (via Dante Virtual Soundcard / RME Digiface), runs the
#    deterministic bdsp::Engine on the audio thread, and supervises it from the
#    control-rate BrainThread. Pulls JUCE via FetchContent on first configure.
#    Disable with -DBUILD_APP=OFF to build only the tests.
# ---------------------------------------------------------------------------
option(BUILD_APP "Build the JUCE standalone appliance (downloads JUCE)" ON)

if(BUILD_APP)
    include(FetchContent)
    FetchContent_Declare(
        JUCE
        GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG        8.0.15
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(JUCE)

    juce_add_console_app(BroadcastMixer PRODUCT_NAME "AutoMix Broadcast Mixer")

    target_sources(BroadcastMixer PRIVATE
        src/Main.cpp
    )
    target_include_directories(BroadcastMixer PRIVATE dsp src)
    target_compile_definitions(BroadcastMixer PRIVATE
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_STANDALONE_APPLICATION=1
    )
    if(MSVC)
        target_compile_options(BroadcastMixer PRIVATE /WX)
    else()
        target_compile_options(BroadcastMixer PRIVATE -Werror)
    endif()
    target_link_libraries(BroadcastMixer PRIVATE
        juce::juce_audio_basics
        juce::juce_audio_devices
        juce::juce_audio_formats
        juce::juce_core
        juce::juce_dsp
        juce::juce_recommended_config_flags
        juce::juce_recommended_warning_flags
    )
endif()
