# What is being built?

Trace Driver and Trace X to Root need to know your design's structure: which statement drives a
signal, which branch writes it, which signals it reads. A waveform alone doesn't contain that. cmux
gets it from **cmux-sv-model**, a small program built on
[slang](https://github.com/MikePopoloski/slang), an open-source SystemVerilog compiler (MIT
license). cmux-sv-model elaborates the same design your editor's slang-server compiles, using the
same build file (`.f`) or top level, and answers cmux's questions about it.

cmux builds cmux-sv-model **once per host and cmux version**, the first time you trace on that
host. Your Mac counts as a host, and so does each SSH host you open designs on. Later traces start
at once.

## What happens during the build

1. **Upload the model's sources.** cmux sends four small files bundled with cmux to the host:
   `build.sh`, `CMakeLists.txt`, `sv_model.cpp` and `sv-model.sh`. That's all it sends.
   **Nothing from your design leaves the host.** Your design's files are read where they already
   are, and only when tracing.
2. **Download slang and its libraries.** The host downloads the source releases of slang, fmt,
   regex and toml++ from GitHub and checks each one's SHA-256 against the value pinned in
   `build.sh`. If a checksum doesn't match, the build stops.
3. **Configure (CMake)** and **Compile.** This needs CMake 3.20 or later, a C++20 compiler (GCC 11
   or later, or Clang 16 or later) and Python 3 on the host. The compile runs at low priority
   (`nice`) with 4 jobs by default. Set `CMUX_SV_MODEL_JOBS` on the host to change that.
4. **Install.** The program is copied to `~/.cache/cmux/sv-model/<version>-<machine>/` on the host.
   The build's scratch folder is deleted.
5. **Loading the design.** cmux-sv-model elaborates your design. After that, tracing starts.

The first build usually takes a few minutes, mostly for the compile. It's slower on a busy shared
host.

## If the build fails

The panel shows the last lines of the build log. The usual causes are:

- CMake, a C++20 compiler or Python 3 is missing on the host.
- The host can't download from GitHub.

Fix the cause, then click **Retry**.

To force a clean rebuild, delete the installed copy on the host, then trace again:

```sh
rm -rf ~/.cache/cmux/sv-model
```

That folder holds nothing else. Deleting it is always safe.
