#include <Bela.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <string>

#define TWINE_EXPOSE_INTERNALS  // init_xenomai() is host-only API, hidden by default
#include <twine/twine.h>

#include <sushi/constants.h>
#include <sushi/reactive_factory.h>
#include <sushi/rt_controller.h>
#include <sushi/sample_buffer.h>
#include <sushi/sushi.h>

static std::unique_ptr<sushi::Sushi> g_sushi;
static std::unique_ptr<sushi::RtController> g_rt;

// Channel mapping: sushi channels 0/1 <-> Bela audio codec, channels 2..9 <->
// Bela analog I/O 0..7 (capelet, unipolar DAC: signals are re-biased 0.5+/-0.5
// on output). SUSHI_IO_CHANNELS env (2..10, default 2) sets the count at
// startup — the default is bit-identical to the historical stereo behaviour.
static int g_channels = 2;
static sushi::ChunkSampleBuffer g_in;
static sushi::ChunkSampleBuffer g_out;

bool setup(BelaContext* context, void* /*userData*/)
{
    // Arm twine's realtime flag so WorkerPool::create_worker_pool() returns the
    // EVL out-of-band pool (otherwise it silently falls back to plain pthreads
    // pinned to cores 0..N-1, ignoring isolcpus).
    twine::init_xenomai();

    sushi::ReactiveFactory factory;

    sushi::SushiOptions options;
    options.frontend_type = sushi::FrontendType::REACTIVE;
    options.config_source = sushi::ConfigurationSource::FILE;
    const char* config_env = std::getenv("SUSHI_CONFIG");
    const char* plugin_env = std::getenv("SUSHI_PLUGIN_PATH");
    const char* log_env    = std::getenv("SUSHI_LOG_LEVEL");
    const char* cores_env  = std::getenv("SUSHI_RT_CORES");
    const char* chans_env  = std::getenv("SUSHI_IO_CHANNELS");
    int rt_cores = cores_env ? std::atoi(cores_env) : 1;
    if (rt_cores < 1 || rt_cores > 3)
    {
        rt_cores = 1;
    }
    g_channels = chans_env ? std::atoi(chans_env) : 2;
    if (g_channels < 2 || g_channels > 10)
    {
        g_channels = 2;
    }
    options.config_filename = config_env ? config_env : "/root/sushi-config.json";
    options.base_plugin_path = plugin_env ? plugin_env : "/usr/lib/vst3";
    options.use_osc = false;
    options.use_grpc = true;
    options.log_level = log_env ? log_env : "warning";
    options.log_file = "/tmp/sushi.log";
    options.rt_cpu_cores = rt_cores;
    options.enable_timings = true;
    options.reactive_audio_inputs = g_channels;
    options.reactive_audio_outputs = g_channels;

    auto [sushi, status] = factory.new_instance(options);
    if (status != sushi::Status::OK)
    {
        rt_fprintf(stderr, "sushi-bela: sushi init failed: %s\n",
                   sushi::to_string(status).c_str());
        return false;
    }

    g_rt = factory.rt_controller();
    if (!g_rt)
    {
        rt_fprintf(stderr, "sushi-bela: failed to get RtController\n");
        return false;
    }

    sushi->set_sample_rate(context->audioSampleRate);

    auto start_status = sushi->start();
    if (start_status != sushi::Status::OK)
    {
        rt_fprintf(stderr, "sushi-bela: sushi start failed: %s\n",
                   sushi::to_string(start_status).c_str());
        return false;
    }

    g_sushi = std::move(sushi);

    g_in = sushi::ChunkSampleBuffer(g_channels);
    g_out = sushi::ChunkSampleBuffer(g_channels);

    rt_fprintf(stderr,
               "sushi-bela: bela ctx — audio %u in/%u out @%g Hz (%u frames), analog %u in/%u out (%u frames)\n",
               context->audioInChannels, context->audioOutChannels,
               context->audioSampleRate, context->audioFrames,
               context->analogInChannels, context->analogOutChannels,
               context->analogFrames);

    rt_fprintf(stderr, "sushi-bela: sushi started (gRPC on :51051, rt_cores=%d, chunk=%d, io_channels=%d)\n",
               rt_cores, sushi::AUDIO_CHUNK_SIZE, g_channels);

    return true;
}

void render(BelaContext* context, void* /*userData*/)
{
    const int frames = context->audioFrames;
    constexpr int chunk = sushi::AUDIO_CHUNK_SIZE;

    // The engine consumes exactly AUDIO_CHUNK_SIZE frames per process_audio()
    // call; feeding it any other amount corrupts memory or desyncs time.
    if (frames % chunk != 0)
    {
        static bool warned = false;
        if (!warned)
        {
            rt_fprintf(stderr, "sushi-bela: period %d incompatible with sushi chunk %d — muting\n",
                       frames, chunk);
            warned = true;
        }
        for (int ch = 0; ch < 2; ch++)
        {
            for (int n = 0; n < frames; n++)
            {
                audioWrite(context, n, ch, 0.0f);
            }
        }
        return;
    }

    // Two possible Bela layouts for the extra channels:
    //  - classic: separate analog context (analogRead/Write, often half rate)
    //  - PB2 multichannel codec: extra channels folded into the AUDIO context
    //    (audioOutChannels > 2) — then audioWrite reaches them directly.
    const int audio_in_ch = static_cast<int>(context->audioInChannels);
    const int audio_out_ch = static_cast<int>(context->audioOutChannels);
    const int analog_frames = context->analogFrames;
    const int analog_ratio = (analog_frames > 0) ? frames / analog_frames : 1;
    const int analog_in = static_cast<int>(context->analogInChannels);
    const int analog_out = static_cast<int>(context->analogOutChannels);

    for (int offset = 0; offset < frames; offset += chunk)
    {
        for (int ch = 0; ch < g_channels; ch++)
        {
            float* dst = g_in.channel(ch);
            if (ch < audio_in_ch)
            {
                for (int n = 0; n < chunk; n++)
                {
                    dst[n] = audioRead(context, offset + n, ch);
                }
            }
            else if (ch - 2 < analog_in)
            {
                // Unipolar ADC 0..1 -> bipolar
                for (int n = 0; n < chunk; n++)
                {
                    dst[n] = 2.0f * analogRead(context, (offset + n) / analog_ratio, ch - 2) - 1.0f;
                }
            }
            else
            {
                std::memset(dst, 0, chunk * sizeof(float));
            }
        }

        auto timestamp = g_rt->calculate_timestamp_from_start(context->audioSampleRate);
        g_rt->process_audio(g_in, g_out, timestamp);
        g_rt->increment_samples_since_start(chunk, timestamp);

        for (int ch = 0; ch < g_channels; ch++)
        {
            const float* src = g_out.channel(ch);
            if (ch < audio_out_ch)
            {
                for (int n = 0; n < chunk; n++)
                {
                    audioWrite(context, offset + n, ch, src[n]);
                }
            }
            else if (ch - 2 < analog_out)
            {
                // Bipolar -> unipolar DAC, clamped to 0..1
                for (int n = 0; n < chunk; n++)
                {
                    float v = 0.5f + 0.5f * src[n];
                    v = (v < 0.0f) ? 0.0f : (v > 1.0f ? 1.0f : v);
                    analogWriteOnce(context, (offset + n) / analog_ratio, ch - 2, v);
                }
            }
        }
    }
}

void cleanup(BelaContext* /*context*/, void* /*userData*/)
{
    if (g_sushi)
    {
        g_sushi->stop();
        g_sushi.reset();
    }
    g_rt.reset();
}
