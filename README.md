# sushi-on-bela

Run the [Sushi](https://github.com/elk-audio/sushi) audio engine — and your JUCE or DPF VST3/LV2 plugins — on a [Bela](https://bela.io) board (PocketBeagle2 / Bela GEM, Debian Bookworm EVL image).

Sushi is embedded as a library inside a Bela `render()` callback: Bela's PRU-driven audio thread feeds Sushi's reactive frontend chunk by chunk, Sushi runs the plugin graph (optionally across multiple cores via twine/EVL worker threads), and exposes its full gRPC control API on port 51051.

What's in here:

| Path | Purpose |
|---|---|
| `docker/` | `elk-crossbuild-bookworm` Docker image: aarch64 cross toolchain, vcpkg, patched gRPC overlay port, build scripts |
| `build-docker-image.sh` | Build the Docker image |
| `setup-bela-sysroot.sh` | Pull Bela/EVL/system libs + headers from the board into `bela-sysroot/` |
| `cross-build-sushi.sh` | Cross-compile Sushi as a reactive static library (`libsushi_library.a`) |
| `cross-build-bela-project.sh` | Compile + link the Bela host (`bela-project/render.cpp`) into the final `sushi` binary |
| `cross-build-plugin.sh` | Cross-compile a JUCE plugin (headless VST3) |
| `cross-build-dpf-plugin.sh` | Cross-compile a DPF/CMake plugin (VST3 + LV2, headless by default) |
| `bela-project/` | The host project: `render.cpp` + example Sushi configs |
| `plugins/HelloSine/` | Minimal JUCE example plugin (sine synth, headless VST3) |

## Requirements

- **Docker** on the build machine (Linux, macOS, or Windows/WSL2).
- A Bela board running the **Bookworm Bela image with the EVL kernel** (6.12+), reachable over SSH as root (default `bela.local`, or `192.168.7.2`/`192.168.6.2` over USB gadget networking).
- The **Sushi fork with reactive multichannel support**: <https://github.com/LeoFabre/sushi/tree/feature/reactive-multichannel> (proposed for upstreaming). Stock upstream Sushi only exposes 2 channels through the reactive frontend; the fork adds up to 10 (and is what `SUSHI_IO_CHANNELS` relies on).

```sh
git clone --recurse-submodules -b feature/reactive-multichannel https://github.com/LeoFabre/sushi.git
```

## Quickstart

```sh
# 1. Build the cross-compilation image (one-time, ~15 min)
./build-docker-image.sh

# 2. Populate bela-sysroot/ from the board (one-time, board must be reachable)
./setup-bela-sysroot.sh             # or ./setup-bela-sysroot.sh 192.168.7.2

# 3. Cross-compile Sushi as a reactive library (twine with EVL workers)
./cross-build-sushi.sh /path/to/sushi -DSUSHI_BUILD_TWINE=ON -DTWINE_WITH_EVL=ON

# 4. Build the Bela host binary (chunk size must match step 3 — see below)
SUSHI_CHUNK=64 ./cross-build-bela-project.sh /path/to/sushi

# 5. Deploy
scp build-arm64/bela-project/sushi root@bela.local:/root/Bela/projects/sushi/
scp bela-project/sushi-config-passthrough.json root@bela.local:/root/sushi-config.json

# 6. Run (on the board)
ssh root@bela.local
cd /root/Bela/projects/sushi
SUSHI_CONFIG=/root/sushi-config.json ./sushi -p 64
```

The binary is a normal Bela project: all standard Bela CLI flags apply (`-p` period, `-D`/`--line-out-level` and `-H`/`--headphone-level` codec output levels in dB, etc.).

### Runtime environment variables

The host reads its configuration from the environment at startup:

| Variable | Default | Meaning |
|---|---|---|
| `SUSHI_CONFIG` | `/root/sushi-config.json` | Sushi JSON session config |
| `SUSHI_PLUGIN_PATH` | `/usr/lib/vst3` | Base path for plugin lookup |
| `SUSHI_RT_CORES` | `1` | Number of RT worker cores (1–3). >1 enables twine multicore processing |
| `SUSHI_IO_CHANNELS` | `2` | Engine I/O channel count (2–10). 2 is bit-identical to plain stereo |
| `SUSHI_LOG_LEVEL` | `warning` | Sushi log level (`debug`, `info`, `warning`, `error`); log file is `/tmp/sushi.log` |

gRPC is always enabled on `:51051`; OSC is disabled.

## The chunk-size ABI rule (important)

Sushi's `ChunkSampleBuffer` is statically sized by `SUSHI_AUDIO_BUFFER_SIZE` **at compile time, on both sides of the library boundary**. The `SUSHI_CHUNK` value passed to `cross-build-bela-project.sh` must match the `SUSHI_AUDIO_BUFFER_SIZE` the library was built with — a mismatch silently corrupts memory.

- `docker/scripts/build-sushi.sh` builds the library with `SUSHI_AUDIO_BUFFER_SIZE=64` by default. To change it, append the CMake flag: `./cross-build-sushi.sh /path/to/sushi -DSUSHI_AUDIO_BUFFER_SIZE=32` (later `-D` flags override the default), then build the host with `SUSHI_CHUNK=32`.
- At runtime, the Bela period (`-p`) must be a **multiple of the chunk size**; otherwise the host logs an error and mutes. Smaller chunks (e.g. 32) lower latency at the cost of per-callback overhead.

## Multichannel I/O

With `SUSHI_IO_CHANNELS=N` (N up to 10), the host maps engine channels to Bela I/O as:

- **Channels 0–1** → the stereo audio codec.
- **Channels 2–9** → the extra channels. On PocketBeagle2/GEM with a multichannel codec, Bela folds these into the audio context at **full audio rate** (`audioInChannels`/`audioOutChannels` > 2) and the host reads/writes them directly. On classic Bela layouts they fall back to the analog I/O channels 0–7 (unipolar ADC/DAC: inputs are rescaled to ±1, outputs re-biased to 0.5 ± 0.5 and clamped).

When checking levels on the codec pair, the Bela CLI flags `-D <dB>` (`--line-out-level`) and `-H <dB>` (`--headphone-level`) set the codec output stages.

Example configs in `bela-project/`:

- `sushi-config-passthrough.json` — single stereo track with a unity gain plugin (Sushi rejects tracks with an empty plugin list, so passthrough = internal gain plugin).
- `sushi-config-hellosine.json` — the HelloSine VST3 on one stereo track.
- `hellosine-multich.json` — HelloSine duplicated to 5 stereo buses (10 channels) via internal send/return pairs; run with `SUSHI_IO_CHANNELS=10`.
- `input-multich-monitor.json` — mixes 5 stereo input buses down to output bus 0; useful to verify all inputs are alive.

## Cross-compiling your plugins

Both scripts auto-build the Docker image if missing and drop bundles in `build-arm64/<plugin-name>/`.

**JUCE** (CMake-based projects; JUCE's `juceaide` is built natively inside the container, the plugin is cross-compiled headless):

```sh
./cross-build-plugin.sh /path/to/my-juce-plugin
scp -r build-arm64/my-juce-plugin/*.vst3 root@bela.local:/usr/lib/vst3/
```

**DPF** (headless by default; `--ui` enables the UI build, the CMake UI option name is auto-detected from `option(<X>_BUILD_UI ...)`):

```sh
./cross-build-dpf-plugin.sh /path/to/my-dpf-plugin
scp -r build-arm64/my-dpf-plugin/*.vst3 root@bela.local:/usr/lib/vst3/
```

`plugins/HelloSine/` is a complete minimal JUCE example you can use to validate the chain end-to-end (`./cross-build-plugin.sh plugins/HelloSine`).

## Real-time / multicore notes

- The host calls `twine::init_xenomai()` before creating Sushi, so with `SUSHI_RT_CORES > 1` twine creates **EVL out-of-band worker threads**. Without it, twine silently falls back to plain pthreads pinned to cores 0..N-1, ignoring core isolation.
- For reliable multicore RT, isolate cores in the kernel cmdline (e.g. in `/boot/firmware/extlinux/extlinux.conf` on the Bookworm image): `isolcpus=1-3 irqaffinity=0 nohz_full=1-3 rcu_nocbs=1-3`. Twine's EVL pool automatically places workers on the isolated cores; keep your non-RT services pinned to core 0.
- Tracks are assigned to workers with the per-track `"thread": <n>` key in the Sushi JSON config (0-based worker index). **Warning: Sushi does not bounds-check this index** — never load a config using `"thread"` placement with `SUSHI_RT_CORES=1` (or fewer cores than the highest index); it reads past the worker array instead of failing cleanly.
- Stale twine semaphores can survive a crash; clear them before restarting: `rm -f /dev/shm/sem.twine_*`.

## License

GPL-3.0-or-later. Sushi and its ecosystem are AGPL/GPL-licensed, and the example plugin chain (JUCE GPL mode, DPF plugins) is GPL — see `LICENSE`.
