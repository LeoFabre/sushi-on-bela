cmake_minimum_required(VERSION 3.22)
project(HelloSine VERSION 1.0.0)

include(FetchContent)
FetchContent_Declare(
    JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG        8.0.4
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(JUCE)

juce_add_plugin(HelloSine
    PLUGIN_MANUFACTURER_CODE LeoF
    PLUGIN_CODE HlSn
    FORMATS VST3
    PRODUCT_NAME "HelloSine"
    IS_SYNTH TRUE
    NEEDS_MIDI_INPUT FALSE
    NEEDS_MIDI_OUTPUT FALSE
    IS_MIDI_EFFECT FALSE
)

target_sources(HelloSine PRIVATE PluginProcessor.cpp)

target_compile_definitions(HelloSine PUBLIC
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
    JUCE_HEADLESS_PLUGIN_CLIENT=1
)

target_link_libraries(HelloSine
    PRIVATE
        juce::juce_audio_processors
        juce::juce_audio_basics
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
)
