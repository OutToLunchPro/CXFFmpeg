# CXFFmpeg

This repository is the **corresponding source** for the [FFmpeg](https://ffmpeg.org) build that ships inside [Coax](https://coaxtheapp.com).

FFmpeg is licensed under the **GNU Lesser General Public License, version 2.1 or later** (LGPL v2.1+). Coax links against FFmpeg, and this repository is published so that anyone receiving Coax can obtain, inspect, and rebuild the exact FFmpeg used.

## What this is

- **FFmpeg version:** `n7.1` (this repository is a fork of [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg) at the `n7.1` tag).
- **Modifications to FFmpeg source:** **none.** No `.c`/`.h` files in the FFmpeg tree are patched. The build is stock FFmpeg `n7.1`, configured demux-only.
- **What Coax adds:** a single build script (`Vendor/build-ffmpeg.sh`) and a Clang module map + shim (`Vendor/CFFmpeg/`) used to package the static libraries as an Apple `.xcframework`. These are the only files added on top of the upstream tree.

## How it is built

Coax compiles FFmpeg with **zero decoders and zero encoders for patent-encumbered audio/video codecs**. FFmpeg is used only to demux containers, parse/reframe bitstreams, mux fMP4, and decode unencumbered text/bitmap subtitle formats. All audio/video decoding is performed at runtime by Apple's VideoToolbox / AudioToolbox, not by FFmpeg.

The exact `configure` invocation — which *is* the complete description of how this build differs from a default FFmpeg build — lives in  :[`Vendor/build-ffmpeg.sh`](Vendor/build-ffmpeg.sh). To reproduce the libraries:

```sh
bash Vendor/build-ffmpeg.sh
```

This produces Vendor/CFFmpeg.xcframework, the static FFmpeg libraries Coax
links against (libavformat, libavcodec, libavutil, merged into one libcffmpeg.a per platform slice).

License

FFmpeg is licensed under the LGPL v2.1 or later. The full license text is in COPYING.LGPLv2.1. Individual source files carry their own copyright headers; those are authoritative

The build script and packaging glue added se made available under the LGPL v2.1+.

Credit

FFmpeg is the work of the FFmpeg project and its many contributors. I'm grateful for it, and that they allow its use under this license.
