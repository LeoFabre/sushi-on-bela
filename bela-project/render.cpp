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

#ifdef SUSHI_BELA_CHUNK_PROFILE
#include <cstdint>
#include <algorithm>

// ---------------------------------------------------------------------------
// Per-chunk timing instrumentation (opt-in: build with SUSHI_PROFILE=1, which
// defines SUSHI_BELA_CHUNK_PROFILE — zero cost otherwise).
//
// Clock: the ARMv8 generic timer virtual counter, read directly with
// `mrs cntvct_el0`. This is a plain register read — no syscall, no vDSO —
// so it is safe from the EVL out-of-band audio thread. cntfrq_el0 gives the
// counter frequency in Hz, so:  microseconds = ticks * 1e6 / cntfrq.
//
// Per render() call we timestamp the entry, then for every chunk iteration
// the boundaries input-copy / process_audio / output-copy. A histogram of
// callback durations (as % of the period budget) and a ring of the worst
// 64 callbacks (with the segment breakdown of their worst chunk iteration)
// are kept in static memory — no allocation, no printing in RT. A low-prio
// AuxiliaryTask scheduled from render() every ~5 s snapshots and fwrites
// everything to /dev/shm/chunkprof.txt (plain volatile copy: approximate
// consistency is acceptable for diagnostics).
// ---------------------------------------------------------------------------

static inline uint64_t prof_now()
{
    uint64_t ticks;
    asm volatile("mrs %0, cntvct_el0" : "=r"(ticks));
    return ticks;
}

static inline uint64_t prof_counter_freq()
{
    uint64_t hz;
    asm volatile("mrs %0, cntfrq_el0" : "=r"(hz));
    return hz;
}

struct ProfEvent
{
    uint64_t wall_ticks;     // cntvct_el0 at render() entry
    uint64_t frames_elapsed; // context->audioFramesElapsed at render() entry
    uint32_t cb_ticks;       // whole-callback duration
    uint32_t in_ticks;       // worst chunk iteration: input copy
    uint32_t proc_ticks;     // worst chunk iteration: process_audio
    uint32_t out_ticks;      // worst chunk iteration: output copy
};

static constexpr int PROF_RING_SIZE = 64;
static constexpr int PROF_HIST_BUCKETS = 6; // <=25/50/75/90/100/>100 % budget

static uint64_t g_prof_freq = 0;            // counter Hz (cntfrq_el0)
static uint64_t g_prof_budget_ticks = 0;    // period / samplerate, in ticks
static uint64_t g_prof_hist_edges[PROF_HIST_BUCKETS - 1]; // tick thresholds
static uint64_t g_prof_hist[PROF_HIST_BUCKETS];
static ProfEvent g_prof_events[PROF_RING_SIZE];
static uint32_t g_prof_filled = 0;          // events stored so far (<= 64)
static uint32_t g_prof_min_idx = 0;         // index of smallest stored event
static uint64_t g_prof_callbacks = 0;
static uint32_t g_prof_dump_period = 0;     // callbacks between dumps (~5 s)
static uint32_t g_prof_dump_counter = 0;
static AuxiliaryTask g_prof_task = nullptr;

// AuxiliaryTask body (non-RT): snapshot + write /dev/shm/chunkprof.txt
static void prof_dump(void* /*arg*/)
{
    // Plain copies — the RT thread may race us, approximate data is fine.
    uint64_t hist[PROF_HIST_BUCKETS];
    ProfEvent events[PROF_RING_SIZE];
    std::memcpy(hist, (const void*) g_prof_hist, sizeof(hist));
    std::memcpy(events, (const void*) g_prof_events, sizeof(events));
    uint32_t filled = g_prof_filled;
    uint64_t callbacks = g_prof_callbacks;

    std::sort(events, events + filled,
              [](const ProfEvent& a, const ProfEvent& b) { return a.cb_ticks > b.cb_ticks; });

    FILE* f = fopen("/dev/shm/chunkprof.txt", "w");
    if (!f)
    {
        return;
    }
    const double us = 1.0e6 / (double) g_prof_freq; // µs per counter tick
    fprintf(f, "chunkprof v1\n");
    fprintf(f, "counter_freq_hz %llu\n", (unsigned long long) g_prof_freq);
    fprintf(f, "budget_us %.3f\n", (double) g_prof_budget_ticks * us);
    fprintf(f, "callbacks %llu\n", (unsigned long long) callbacks);
    static const char* bucket_names[PROF_HIST_BUCKETS] =
        {"le25", "le50", "le75", "le90", "le100", "over100"};
    for (int i = 0; i < PROF_HIST_BUCKETS; i++)
    {
        fprintf(f, "hist_%s %llu\n", bucket_names[i], (unsigned long long) hist[i]);
    }
    fprintf(f, "worst_events %u\n", filled);
    fprintf(f, "# rank cb_us in_us proc_us out_us frames_elapsed wall_s\n");
    for (uint32_t i = 0; i < filled; i++)
    {
        const ProfEvent& e = events[i];
        fprintf(f, "event %u %.2f %.2f %.2f %.2f %llu %.6f\n",
                i,
                e.cb_ticks * us, e.in_ticks * us, e.proc_ticks * us, e.out_ticks * us,
                (unsigned long long) e.frames_elapsed,
                (double) e.wall_ticks / (double) g_prof_freq);
    }
    fclose(f);
}

// RT-side: histogram + worst-events ring bookkeeping (no allocation).
static inline void prof_record(uint64_t wall_ticks, uint64_t frames_elapsed,
                               uint64_t cb_ticks, uint64_t in_ticks,
                               uint64_t proc_ticks, uint64_t out_ticks)
{
    int bucket = PROF_HIST_BUCKETS - 1;
    for (int i = 0; i < PROF_HIST_BUCKETS - 1; i++)
    {
        if (cb_ticks <= g_prof_hist_edges[i])
        {
            bucket = i;
            break;
        }
    }
    g_prof_hist[bucket]++;

    if (g_prof_filled < PROF_RING_SIZE || cb_ticks > g_prof_events[g_prof_min_idx].cb_ticks)
    {
        uint32_t slot = (g_prof_filled < PROF_RING_SIZE) ? g_prof_filled++ : g_prof_min_idx;
        g_prof_events[slot] = ProfEvent{wall_ticks, frames_elapsed,
                                        (uint32_t) cb_ticks, (uint32_t) in_ticks,
                                        (uint32_t) proc_ticks, (uint32_t) out_ticks};
        if (g_prof_filled == PROF_RING_SIZE) // full: refresh the min slot
        {
            g_prof_min_idx = 0;
            for (uint32_t i = 1; i < PROF_RING_SIZE; i++)
            {
                if (g_prof_events[i].cb_ticks < g_prof_events[g_prof_min_idx].cb_ticks)
                {
                    g_prof_min_idx = i;
                }
            }
        }
    }
}
#endif // SUSHI_BELA_CHUNK_PROFILE

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

#ifdef SUSHI_BELA_CHUNK_PROFILE
    g_prof_freq = prof_counter_freq();
    // Budget = one period of audio: frames / samplerate seconds, in ticks.
    g_prof_budget_ticks = (uint64_t) ((double) g_prof_freq * context->audioFrames
                                      / context->audioSampleRate);
    static const double edges_pct[PROF_HIST_BUCKETS - 1] = {0.25, 0.50, 0.75, 0.90, 1.00};
    for (int i = 0; i < PROF_HIST_BUCKETS - 1; i++)
    {
        g_prof_hist_edges[i] = (uint64_t) (g_prof_budget_ticks * edges_pct[i]);
    }
    // Schedule a dump roughly every 5 seconds of audio.
    g_prof_dump_period = (uint32_t) (5.0 * context->audioSampleRate / context->audioFrames);
    g_prof_task = Bela_createAuxiliaryTask(prof_dump, 50, "chunkprof-dump", nullptr);
    if (!g_prof_task)
    {
        rt_fprintf(stderr, "sushi-bela: failed to create chunkprof AuxiliaryTask\n");
        return false;
    }
    rt_fprintf(stderr,
               "sushi-bela: chunk profiling ON (counter %llu Hz, budget %.1f us, dump every %u callbacks)\n",
               (unsigned long long) g_prof_freq,
               (double) g_prof_budget_ticks * 1.0e6 / (double) g_prof_freq,
               g_prof_dump_period);
#endif

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

#ifdef SUSHI_BELA_CHUNK_PROFILE
    const uint64_t prof_t0 = prof_now();
    uint64_t prof_worst_iter = 0; // worst chunk iteration (total ticks)
    uint64_t prof_w_in = 0, prof_w_proc = 0, prof_w_out = 0;
#endif

    for (int offset = 0; offset < frames; offset += chunk)
    {
#ifdef SUSHI_BELA_CHUNK_PROFILE
        const uint64_t prof_it0 = prof_now();
#endif
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

#ifdef SUSHI_BELA_CHUNK_PROFILE
        const uint64_t prof_t_in = prof_now(); // input copy done
#endif

        auto timestamp = g_rt->calculate_timestamp_from_start(context->audioSampleRate);
        g_rt->process_audio(g_in, g_out, timestamp);
        g_rt->increment_samples_since_start(chunk, timestamp);

#ifdef SUSHI_BELA_CHUNK_PROFILE
        const uint64_t prof_t_proc = prof_now(); // process_audio done
#endif

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

#ifdef SUSHI_BELA_CHUNK_PROFILE
        const uint64_t prof_t_out = prof_now(); // output copy done
        const uint64_t iter = prof_t_out - prof_it0;
        if (iter >= prof_worst_iter)
        {
            prof_worst_iter = iter;
            prof_w_in = prof_t_in - prof_it0;
            prof_w_proc = prof_t_proc - prof_t_in;
            prof_w_out = prof_t_out - prof_t_proc;
        }
#endif
    }

#ifdef SUSHI_BELA_CHUNK_PROFILE
    g_prof_callbacks++;
    prof_record(prof_t0, context->audioFramesElapsed,
                prof_now() - prof_t0, prof_w_in, prof_w_proc, prof_w_out);
    if (++g_prof_dump_counter >= g_prof_dump_period)
    {
        g_prof_dump_counter = 0;
        Bela_scheduleAuxiliaryTask(g_prof_task);
    }
#endif
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
