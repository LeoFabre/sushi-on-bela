#include <juce_audio_processors/juce_audio_processors.h>
#include <cmath>

class HelloSineProcessor : public juce::AudioProcessor
{
public:
    HelloSineProcessor()
        : AudioProcessor(BusesProperties()
              .withOutput("Output", juce::AudioChannelSet::stereo(), true))
    {
    }

    const juce::String getName() const override { return "HelloSine"; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    double getTailLengthSeconds() const override { return 0.0; }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram(int) override {}
    const juce::String getProgramName(int) override { return {}; }
    void changeProgramName(int, const juce::String&) override {}

    bool hasEditor() const override { return false; }
    juce::AudioProcessorEditor* createEditor() override { return nullptr; }

    void getStateInformation(juce::MemoryBlock&) override {}
    void setStateInformation(const void*, int) override {}

    void prepareToPlay(double sampleRate, int) override
    {
        sr = sampleRate;
        sinePhase = 0.0;
        lfoPhase = 0.0;
    }

    void releaseResources() override {}

    void processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override
    {
        const int numSamples = buffer.getNumSamples();
        const int numChannels = buffer.getNumChannels();

        constexpr double sineFreq = 440.0;
        constexpr double lfoFreq = 2.0; // period = 0.5s

        const double sineInc = juce::MathConstants<double>::twoPi * sineFreq / sr;
        const double lfoInc = juce::MathConstants<double>::twoPi * lfoFreq / sr;

        for (int i = 0; i < numSamples; ++i)
        {
            float lfo = static_cast<float>(0.5 + 0.5 * std::sin(lfoPhase));
            float sample = static_cast<float>(std::sin(sinePhase)) * lfo * 0.5f;

            for (int ch = 0; ch < numChannels; ++ch)
                buffer.setSample(ch, i, sample);

            sinePhase += sineInc;
            lfoPhase += lfoInc;
        }

        if (sinePhase > juce::MathConstants<double>::twoPi * 1000.0)
            sinePhase = std::fmod(sinePhase, juce::MathConstants<double>::twoPi);
        if (lfoPhase > juce::MathConstants<double>::twoPi * 1000.0)
            lfoPhase = std::fmod(lfoPhase, juce::MathConstants<double>::twoPi);
    }

private:
    double sr = 44100.0;
    double sinePhase = 0.0;
    double lfoPhase = 0.0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(HelloSineProcessor)
};

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new HelloSineProcessor();
}
