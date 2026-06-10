# sushi-on-bela

Run the [Sushi](https://github.com/elk-audio/sushi) audio engine — and your JUCE or DPF VST3/LV2 plugins — on a [Bela](https://bela.io) board (PocketBeagle2 / Bela GEM, Debian Bookworm EVL image).

Sushi is embedded as a library inside a Bela `render()` callback: Bela's PRU-driven audio thread feeds Sushi's reactive frontend chunk by chunk, Sushi runs the plugin graph (optionally across multiple cores via twine/EVL worker threads), and exposes its full gRPC control API on port 51051.

**Table of contents**

- [What's in this repo](#whats-in-this-repo)
- [Prerequisites](#prerequisites)
- [Step-by-step setup guide](#step-by-step-setup-guide)
  - [Step 1 — Clone this repo](#step-1--clone-this-repo)
  - [Step 2 — Build the Docker cross-compilation image](#step-2--build-the-docker-cross-compilation-image)
  - [Step 3 — Pull the sysroot from your board](#step-3--pull-the-sysroot-from-your-board)
  - [Step 4 — Cross-compile Sushi](#step-4--cross-compile-sushi)
  - [Step 5 — Cross-compile the Bela host binary](#step-5--cross-compile-the-bela-host-binary)
  - [Step 6 — Deploy to the board](#step-6--deploy-to-the-board)
  - [Step 7 — First run](#step-7--first-run)
  - [Step 8 — Going further](#step-8--going-further)
- [Runtime environment variables](#runtime-environment-variables)
- [The chunk-size ABI rule](#the-chunk-size-abi-rule-important)
- [Multichannel I/O](#multichannel-io)
- [Cross-compiling your plugins](#cross-compiling-your-plugins)
- [Real-time / multicore notes](#real-time--multicore-notes)
- [License](#license)

---

## What's in this repo

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

---

## Prerequisites

Before you start, make sure you have the following installed and configured on your build machine.

### Docker

The entire cross-compilation toolchain runs inside Docker — you do not need to install an ARM toolchain locally.

- **Linux:** [https://docs.docker.com/engine/install/](https://docs.docker.com/engine/install/)
- **macOS / Windows:** [https://docs.docker.com/desktop/](https://docs.docker.com/desktop/)

The Docker image + vcpkg build caches (gRPC, protobuf, etc.) consume roughly **10 GB** of disk space on the first build. Make sure you have that free before you begin.

Verify Docker is working:

```sh
docker run --rm hello-world
```

### Git (with submodule support)

Git 2.x is required; the Sushi source tree uses submodules.

- [https://git-scm.com/downloads](https://git-scm.com/downloads)

Verify:

```sh
git --version   # should print git version 2.x.x
```

### A Bela board flashed with the Bookworm EVL image

This toolkit targets Debian Bookworm with the **EVL real-time kernel (6.12+)**. The EVL kernel is required for twine's out-of-band worker threads; the board will not boot the `sushi` binary built with `-DTWINE_WITH_EVL=ON` on a non-EVL image.

- Bela documentation: [https://learn.bela.io/](https://learn.bela.io/)
- Bookworm EVL image releases: [https://github.com/BelaPlatform/bela-image-builder/releases](https://github.com/BelaPlatform/bela-image-builder/releases)

Flash the image to your board's SD card following the Bela documentation before proceeding.

### SSH access to the board

The setup and deploy steps connect to the board over SSH as `root`. The default hostname is `bela.local`; you can also use the USB gadget IP (`192.168.7.2` on Linux/Windows, `192.168.6.2` on macOS).

- SSH setup guide: [https://learn.bela.io/using-bela/technical-explanations/ssh/](https://learn.bela.io/using-bela/technical-explanations/ssh/)

Verify:

```sh
ssh root@bela.local "echo ok"   # should print: ok
```

### The Sushi source tree (reactive-multichannel fork)

The host is built against a fork of Sushi that adds reactive multichannel support (up to 10 channels through the reactive frontend). This fork has been proposed for upstreaming to [elk-audio/sushi](https://github.com/elk-audio/sushi); stock upstream only exposes 2 channels and will not work with `SUSHI_IO_CHANNELS > 2`.

Clone it alongside this repo (the exact location on disk does not matter; you will pass the path to the build scripts):

```sh
git clone --recurse-submodules -b feature/reactive-multichannel \
    https://github.com/LeoFabre/sushi.git
```

This clones a large tree with many submodules — allow a few minutes. Verify:

```sh
ls sushi/include/sushi_interface.h   # should exist
```

---

## Step-by-step setup guide

### Step 1 — Clone this repo

```sh
git clone https://github.com/LeoFabre/sushi-on-bela.git
cd sushi-on-bela
```

Verify: you should see `build-docker-image.sh`, `cross-build-sushi.sh`, and the `bela-project/` directory.

```sh
ls build-docker-image.sh cross-build-sushi.sh bela-project/
```

---

### Step 2 — Build the Docker cross-compilation image

This step builds the `elk-crossbuild-bookworm` Docker image containing the aarch64 cross toolchain, vcpkg, and all build scripts. It is a one-time operation (subsequent builds are incremental unless you pass `--no-cache`).

```sh
./build-docker-image.sh
```

Expected duration: **10–20 minutes** on a fast connection (downloads the base image and toolchain layers).

**Verify:**

```sh
docker image ls | grep elk-crossbuild
```

You should see a line like:

```
elk-crossbuild-bookworm   latest   <id>   <time>   <size>
```

> Tip: if you need to rebuild from scratch (e.g. after a Dockerfile change), run `./build-docker-image.sh --no-cache`.

---

### Step 3 — Pull the sysroot from your board

The sysroot contains the Bela libraries, EVL headers, and system shared libraries that the final binary links against at runtime on the board. You must run this once with the board connected and reachable.

```sh
./setup-bela-sysroot.sh             # uses bela.local
# or:
./setup-bela-sysroot.sh 192.168.7.2  # use the board's IP if hostname doesn't resolve
```

The script copies files into `bela-sysroot/` in this repo.

**Verify:** the script prints a file listing at the end. You should see at least:

```
bela-sysroot/lib/libbela.so
bela-sysroot/lib/libbela.a
bela-sysroot/lib/evl/libevl.a
bela-sysroot/lib/aarch64-linux-gnu/libc.so.6
```

---

### Step 4 — Cross-compile Sushi

This step builds Sushi as a static reactive library (`libsushi_library.a`) for aarch64. All heavy dependencies (gRPC, protobuf, abseil, etc.) are compiled via vcpkg inside Docker and cached in Docker volumes — the **first build takes 30–60 minutes**; incremental rebuilds are fast.

```sh
./cross-build-sushi.sh /path/to/sushi \
    -DSUSHI_BUILD_TWINE=ON \
    -DTWINE_WITH_EVL=ON
```

Replace `/path/to/sushi` with the path to the `sushi` directory you cloned in the Prerequisites section.

The `-DSUSHI_BUILD_TWINE=ON -DTWINE_WITH_EVL=ON` flags enable EVL out-of-band worker threads for multicore RT processing. Omit them if you only need single-core operation and do not have the EVL kernel.

**Verify:** the script prints the output directory listing. You should see:

```
build-arm64/sushi/libsushi_library.a
```

> To wipe all caches and rebuild from scratch: `./cross-build-sushi.sh /path/to/sushi --clean -DSUSHI_BUILD_TWINE=ON -DTWINE_WITH_EVL=ON`

---

### Step 5 — Cross-compile the Bela host binary

This step compiles `bela-project/render.cpp` and links it against `libsushi_library.a` and the Bela sysroot, producing the final `sushi` binary for the board.

The `SUSHI_CHUNK` variable sets the audio chunk size in samples. **It must match the `SUSHI_AUDIO_BUFFER_SIZE` the library was built with** — the default is `64`. See [The chunk-size ABI rule](#the-chunk-size-abi-rule-important) below for the full explanation.

```sh
SUSHI_CHUNK=64 ./cross-build-bela-project.sh /path/to/sushi
```

**Verify:** the script prints the binary size and path:

```
Output: build-arm64/bela-project/sushi
```

```sh
file build-arm64/bela-project/sushi
# should print: ELF 64-bit LSB executable, ARM aarch64
```

---

### Step 6 — Deploy to the board

Copy the binary and a Sushi config to the board. For the first run, use the HelloSine example config, which plays a 440 Hz sine tone. You will also need the HelloSine VST3 plugin on the board.

**Build and deploy HelloSine:**

```sh
# Cross-compile the HelloSine example plugin
./cross-build-plugin.sh plugins/HelloSine

# Copy the VST3 bundle to the board
scp -r build-arm64/HelloSine/*.vst3 root@bela.local:/usr/lib/vst3/
```

**Deploy the binary and config:**

```sh
# Create the project directory on the board if it doesn't exist
ssh root@bela.local "mkdir -p /root/Bela/projects/sushi"

# Copy the sushi binary
scp build-arm64/bela-project/sushi root@bela.local:/root/Bela/projects/sushi/

# Copy the HelloSine config
scp bela-project/sushi-config-hellosine.json root@bela.local:/root/sushi-config.json
```

**Verify** the files landed on the board:

```sh
ssh root@bela.local "ls -lh /root/Bela/projects/sushi/sushi /root/sushi-config.json /usr/lib/vst3/"
```

---

### Step 7 — First run

Connect headphones or speakers to the board's audio output, then start Sushi:

```sh
ssh root@bela.local \
  "SUSHI_CONFIG=/root/sushi-config.json /root/Bela/projects/sushi/sushi -p 64"
```

- `-p 64` sets the Bela period to 64 frames (must be a multiple of the chunk size — both are 64 here).
- You should hear a **440 Hz sine tone** within a second or two of the command running.

**Where logs land:**

Sushi writes its log to `/tmp/sushi.log` on the board. To watch it in real time from another terminal:

```sh
ssh root@bela.local "tail -f /tmp/sushi.log"
```

To increase verbosity, prefix the run command with `SUSHI_LOG_LEVEL=info` (or `debug`).

**How to stop:**

Press `Ctrl+C` in the SSH session, or from another terminal:

```sh
ssh root@bela.local "pkill -x sushi"
```

> Note: use `pkill -x sushi` (exact match), not `pkill -f sushi` — the latter can match and kill the SSH session itself.

---

### Step 8 — Going further

Once the HelloSine example is running, explore the rest of this guide:

- **More example configs** — `bela-project/sushi-config-passthrough.json` (stereo passthrough), `bela-project/hellosine-multich.json` (5 stereo buses / 10 channels), `bela-project/input-multich-monitor.json` (mix 5 input buses to output 0).
- **Runtime tuning** — see the [Runtime environment variables](#runtime-environment-variables) table (`SUSHI_RT_CORES`, `SUSHI_IO_CHANNELS`, `SUSHI_LOG_LEVEL`, etc.).
- **Multichannel I/O** — see the [Multichannel I/O](#multichannel-io) section.
- **Building your own JUCE or DPF plugins** — see [Cross-compiling your plugins](#cross-compiling-your-plugins).
- **Real-time multicore operation** — see [Real-time / multicore notes](#real-time--multicore-notes) for core isolation, twine EVL threads, and `SUSHI_RT_CORES`.

---

## Runtime environment variables

The host reads its configuration from the environment at startup:

| Variable | Default | Meaning |
|---|---|---|
| `SUSHI_CONFIG` | `/root/sushi-config.json` | Sushi JSON session config |
| `SUSHI_PLUGIN_PATH` | `/usr/lib/vst3` | Base path for plugin lookup |
| `SUSHI_RT_CORES` | `1` | Number of RT worker cores (1–3). >1 enables twine multicore processing |
| `SUSHI_IO_CHANNELS` | `2` | Engine I/O channel count (2–10). 2 is bit-identical to plain stereo |
| `SUSHI_LOG_LEVEL` | `warning` | Sushi log level (`debug`, `info`, `warning`, `error`); log file is `/tmp/sushi.log` |

gRPC is always enabled on `:51051`; OSC is disabled.

The binary is a normal Bela project: all standard Bela CLI flags apply (`-p` period, `-D`/`--line-out-level` and `-H`/`--headphone-level` codec output levels in dB, etc.).

---

## The chunk-size ABI rule (important)

Sushi's `ChunkSampleBuffer` is statically sized by `SUSHI_AUDIO_BUFFER_SIZE` **at compile time, on both sides of the library boundary**. The `SUSHI_CHUNK` value passed to `cross-build-bela-project.sh` must match the `SUSHI_AUDIO_BUFFER_SIZE` the library was built with — a mismatch silently corrupts memory.

- `docker/scripts/build-sushi.sh` builds the library with `SUSHI_AUDIO_BUFFER_SIZE=64` by default. To change it, append the CMake flag: `./cross-build-sushi.sh /path/to/sushi -DSUSHI_AUDIO_BUFFER_SIZE=32` (later `-D` flags override the default), then build the host with `SUSHI_CHUNK=32`.
- At runtime, the Bela period (`-p`) must be a **multiple of the chunk size**; otherwise the host logs an error and mutes. Smaller chunks (e.g. 32) lower latency at the cost of per-callback overhead.

---

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

---

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

---

## Real-time / multicore notes

- The host calls `twine::init_xenomai()` before creating Sushi, so with `SUSHI_RT_CORES > 1` twine creates **EVL out-of-band worker threads**. Without it, twine silently falls back to plain pthreads pinned to cores 0..N-1, ignoring core isolation.
- For reliable multicore RT, isolate cores in the kernel cmdline (e.g. in `/boot/firmware/extlinux/extlinux.conf` on the Bookworm image): `isolcpus=1-3 irqaffinity=0 nohz_full=1-3 rcu_nocbs=1-3`. Twine's EVL pool automatically places workers on the isolated cores; keep your non-RT services pinned to core 0.
- Tracks are assigned to workers with the per-track `"thread": <n>` key in the Sushi JSON config (0-based worker index). **Warning: Sushi does not bounds-check this index** — never load a config using `"thread"` placement with `SUSHI_RT_CORES=1` (or fewer cores than the highest index); it reads past the worker array instead of failing cleanly.
- Stale twine semaphores can survive a crash; clear them before restarting: `rm -f /dev/shm/sem.twine_*`.

---

## License

GPL-3.0-or-later. Sushi and its ecosystem are AGPL/GPL-licensed, and the example plugin chain (JUCE GPL mode, DPF plugins) is GPL — see `LICENSE`.
