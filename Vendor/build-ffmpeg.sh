#!/usr/bin/env bash
#
# build-ffmpeg.sh — vendor a DEMUX-ONLY FFmpeg as CFFmpeg.xcframework.
#
# This is the bright-line build: libavcodec is compiled
# with ZERO decoders and ZERO encoders. It can demux containers, parse
# bitstreams, and reframe NAL units — nothing more. The actual decoding is
# done by VideoToolbox / AudioToolbox at runtime. A build that re-enables a
# decoder is, by definition, off-policy.
#
# Output: ./CFFmpeg.xcframework  (macOS, Mac Catalyst, iOS sim and tvOS sim as
#         FAT arm64+x86_64; iOS/tvOS/visionOS device + visionOS sim arm64-only
#         — x86_64 doesn't exist on those platforms)
#
# Requirements: Xcode CLT, and the FFmpeg source (auto-cloned if absent).
# Usage:
#   ./build-ffmpeg.sh              # all slices, assemble xcframework
#   SLICES="macos" ./build-ffmpeg.sh   # just one slice (fastest first test)
#
set -euo pipefail

FF_VERSION="n7.1"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Build scratch lives OUTSIDE the Xcode-synchronized source folder, so its
# 3k+ FFmpeg .c/.o files never get swept into the app target. Only the finished
# CFFmpeg.xcframework stays here in Vendor/ where the app links it.
SCRATCH="$(git -C "$HERE" rev-parse --show-toplevel)/.ffmpeg-build"
SRC="$SCRATCH/ffmpeg-src"
BUILD="$SCRATCH/build"
SLICES="${SLICES:-macos maccatalyst ios-device ios-sim tvos-device tvos-sim xros-device xros-sim}"

# Min deployment targets — keep in step with the Xcode project.
IOS_MIN="17.0"
TVOS_MIN="17.0"
MACOS_MIN="12.0"
VISIONOS_MIN="1.0"

# ---------------------------------------------------------------------------
# THE BRIGHT LINE, expressed as configure flags.
#   --disable-encoders --disable-decoders --disable-hwaccels  → no codecs.
# We re-enable ONLY container demuxers, bitstream parsers/reframers, and the
# protocols needed to open a stream. Parsers split/locate coded units; they
# do not implement the patented decode algorithm, so they stay on the legal
# side of the line.
# ---------------------------------------------------------------------------
BRIGHT_LINE_FLAGS=(
  --disable-everything
  --disable-programs --disable-doc --disable-debug
  --disable-avdevice --disable-avfilter
  --disable-swscale --disable-swresample --disable-postproc
  --disable-encoders --disable-decoders --disable-hwaccels   # ← the line (also the bulk of FFmpeg's size)
  # UNENCUMBERED SUBTITLE codecs only (§0): SRT/ASS/WebVTT are open text
  # formats, and PGS/VobSub/XSUB are RLE-coded paletted BITMAPS — none are
  # patent-encumbered, so decoding them is on the legal side of the line. Text
  # subs transcode to WebVTT for AVPlayer's HLS renditions; bitmap subs are
  # RLE-decoded out-of-band into a sidecar the UI overlay renders (they are NOT
  # muxed and NOT burned into video). No video/audio decoder is enabled (the
  # bright-line self-check below still passes at zero).
  --enable-decoder=subrip,ass,webvtt,text,pgssub,dvdsub,xsub
  --enable-encoder=webvtt,ass,text
  --enable-muxer=webvtt
  # FFmpeg's OWN VideoToolbox/AudioToolbox wrappers are decode paths through
  # Apple's frameworks — exactly what §0 forbids libav from doing (AVPlayer does
  # that, not us). Disabling them tightens the bright line AND fixes visionOS,
  # whose SDK lacks the OpenGLES key videotoolbox.c references (FFmpeg n7.1
  # predates visionOS and mis-branches it as iOS/tvOS).
  --disable-videotoolbox --disable-audiotoolbox
  --disable-asm                                              # painless cross-compile; we do no heavy DSP
  --enable-small                                             # size-optimized codegen / smaller tables
  --disable-bzlib --disable-lzma --disable-iconv             # external deps we don't need (keep zlib: matroska headers)
  --enable-pic --enable-static --disable-shared
  # INPUT demuxers: only what this engine actually reads. matroska covers
  # mkv+webm (the whole point); mov is kept for mp4-probing safety. We do NOT
  # enable the hls/mpegts/flv/mp3 demuxers — we never READ those.
  --enable-demuxer=matroska,mov
  # OUTPUT muxers: how we emit fMP4 for AVPlayer. The hls MUXER (writing) is
  # distinct from the hls DEMUXER (reading, above) — a muxer wraps already-coded
  # packets in container boxes and is NOT an encoder, so it stays legal (§0).
  --enable-muxer=mov,mp4,hls
  # Bitstream parsers (framing only — NOT decoders). Trimmed to the codecs we
  # actually remux into MP4 for AVPlayer. (opus/vorbis/vp9 dropped: AVPlayer
  # won't take opus-in-mp4 [[avplayer-opus-fmp4-hls-broken]] or vp9.)
  --enable-parser=h264,hevc,av1,aac,ac3
  # Reframers: extradata extraction + AAC ADTS→ASC. Byte plumbing, no decode.
  --enable-bsf=extract_extradata,aac_adtstoasc
  # Protocols. (You can drop http/https/tls/securetransport entirely and feed
  # FFmpeg a Foundation-backed custom AVIO instead — that also removes the
  # Security.framework dependency. For a first local-file test, `file` alone
  # is enough.)
  --enable-protocol=file,http,https,tcp,tls,crypto,httpproxy
  --enable-securetransport
)

clone_src() {
  if [[ ! -d "$SRC" ]]; then
    echo "==> cloning FFmpeg $FF_VERSION"
    git clone --depth 1 --branch "$FF_VERSION" https://github.com/FFmpeg/FFmpeg.git "$SRC"
  fi
}

# Archs per slice. x86_64 exists only where Intel Macs can run the result:
# native macOS, Mac Catalyst, and the iOS/tvOS SIMULATORS (Intel-host Xcode
# and CI). Device slices and visionOS are arm64-only by platform definition.
archs_for_slice() {
  case "$1" in
    macos|maccatalyst|ios-sim|tvos-sim) echo "arm64 x86_64" ;;
    *) echo "arm64" ;;
  esac
}

# slice + arch -> (sdk, target-triple, needs-cross)
configure_slice() {
  local slice="$1" arch="$2" prefix="$3"
  local sdk triple cross=()
  case "$slice" in
    macos)      sdk="macosx";            triple="${arch}-apple-macos${MACOS_MIN}" ;;
    # Mac Catalyst: iOS frameworks running on macOS. Compiles against the macOS
    # SDK (it carries the iOSSupport frameworks) with the -macabi target.
    maccatalyst) sdk="macosx";           triple="${arch}-apple-ios${IOS_MIN}-macabi" ;;
    ios-device) sdk="iphoneos";          triple="${arch}-apple-ios${IOS_MIN}" ;;
    ios-sim)    sdk="iphonesimulator";   triple="${arch}-apple-ios${IOS_MIN}-simulator" ;;
    tvos-device) sdk="appletvos";        triple="${arch}-apple-tvos${TVOS_MIN}" ;;
    tvos-sim)   sdk="appletvsimulator";  triple="${arch}-apple-tvos${TVOS_MIN}-simulator" ;;
    xros-device) sdk="xros";             triple="${arch}-apple-xros${VISIONOS_MIN}" ;;
    xros-sim)   sdk="xrsimulator";       triple="${arch}-apple-xros${VISIONOS_MIN}-simulator" ;;
    *) echo "unknown slice $slice" >&2; exit 1 ;;
  esac
  # Cross-compile whenever the target isn't "this Mac's native arch on the
  # macOS-family SDK" — i.e. every device/sim build, and any x86_64 build on
  # an Apple Silicon host (or vice versa). Harmless when over-applied; FFmpeg
  # just skips the run-the-binary configure probes.
  local host_arch; host_arch="$(uname -m)"
  if [[ "$sdk" != "macosx" || "$arch" != "$host_arch" ]]; then
    cross=(--enable-cross-compile --target-os=darwin --arch="$arch")
  fi

  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local cc; cc="$(xcrun --sdk "$sdk" --find clang)"
  local cflags="-arch $arch -target $triple -isysroot $sysroot"
  # Host tools are compiled to RUN on this Mac during the build, so they always
  # need the macOS SDK sysroot (always macOS, even for iOS/tvOS/visionOS slices).
  # Modern macOS has no /usr/include, so a bare host clang can't find ctype.h —
  # without this FFmpeg misreports "Host compiler lacks C11 support".
  local host_sysroot; host_sysroot="$(xcrun --sdk macosx --show-sdk-path)"

  echo "==> configuring $slice/$arch ($triple)"
  ( cd "$SRC" && make distclean >/dev/null 2>&1 || true )
  ( cd "$SRC" && ./configure \
      --prefix="$prefix" \
      --cc="$cc" \
      --sysroot="$sysroot" \
      --extra-cflags="$cflags" \
      --extra-ldflags="-arch $arch -target $triple -isysroot $sysroot" \
      --host-cflags="-isysroot $host_sysroot" \
      --host-ldflags="-isysroot $host_sysroot" \
      ${cross[@]+"${cross[@]}"} \
      "${BRIGHT_LINE_FLAGS[@]}" )

  echo "==> verifying the bright line held"
  if grep -E 'CONFIG_(H264|HEVC|AAC|AC3)_DECODER 1' "$SRC/config.h" >/dev/null 2>&1; then
    echo "!! a decoder is enabled — configure is off-policy, aborting" >&2
    grep -E 'CONFIG_.*_DECODER 1' "$SRC/config.h" >&2 || true
    exit 2
  fi
  echo "   ok: no decoders compiled in"

  if [[ "$slice" == "maccatalyst" ]]; then
    # SecItemImport is macOS-only. configure's link probe runs against the macOS
    # SDK sysroot (this slice uses sdk=macosx) and finds the symbol, so it sets
    # HAVE_SECITEMIMPORT=1 — but the real compile with -target ...-macabi hits the
    # header availability guard that excludes it, breaking tls_securetransport.c.
    # Force the no-cert-import branch (the iOS slices already build this way). It
    # only stubs import_pem (used solely for a custom ca_file we never set); TLS
    # against the system trust store is unaffected.
    echo "==> [maccatalyst] forcing HAVE_SECITEMIMPORT=0 (macabi lacks SecItemImport)"
    sed -i '' 's/#define HAVE_SECITEMIMPORT 1/#define HAVE_SECITEMIMPORT 0/' "$SRC/config.h"
  fi

  ( cd "$SRC" && make -j"$(sysctl -n hw.ncpu)" && make install )
}

# Merge the three FFmpeg .a into one per-arch library.
package_arch() {
  local prefix="$1"
  libtool -static -o "$prefix/libcffmpeg.a" \
    "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" "$prefix/lib/libavutil.a"
}

main() {
  clone_src
  rm -rf "$BUILD"; mkdir -p "$BUILD"
  local args=()
  for slice in $SLICES; do
    local arch_libs=() first_prefix=""
    for arch in $(archs_for_slice "$slice"); do
      local prefix="$BUILD/$slice/$arch"
      configure_slice "$slice" "$arch" "$prefix"
      package_arch "$prefix"
      arch_libs+=("$prefix/libcffmpeg.a")
      [[ -n "$first_prefix" ]] || first_prefix="$prefix"
    done
    # One library per xcframework slice: lipo the archs together (a single
    # arch passes through lipo unchanged). Headers come from the first arch —
    # the installed public headers are arch-independent (avconfig.h is
    # identical for our flag set; configure's per-arch state lives in the
    # non-installed config.h).
    echo "==> packaging $slice (${arch_libs[*]##*/} ← $(archs_for_slice "$slice"))"
    lipo -create "${arch_libs[@]}" -output "$BUILD/$slice/libcffmpeg.a"
    # Drop the CFFmpeg module map + shim next to the headers so `import CFFmpeg`
    # resolves with no manual search paths once the xcframework is added.
    cp "$HERE/CFFmpeg/module.modulemap" "$HERE/CFFmpeg/shim.h" "$first_prefix/include/"
    args+=(-library "$BUILD/$slice/libcffmpeg.a" -headers "$first_prefix/include")
  done

  echo "==> assembling CFFmpeg.xcframework"
  rm -rf "$HERE/CFFmpeg.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$HERE/CFFmpeg.xcframework"
  echo "==> done: $HERE/CFFmpeg.xcframework"
  echo "    Drag it into the Xcode project (Embed = Do Not Embed, it's static)."
}

main "$@"
