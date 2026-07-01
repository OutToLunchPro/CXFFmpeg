//
//  shim.h — CFFmpeg module umbrella + Swift-bridging helpers.
//
//  Swift can call the bulk of libav* directly (avformat_open_input,
//  av_read_frame, avcodec_parameters_*, etc.). A handful of FFmpeg surface
//  is macros / compound-literal macros / errno-derived codes that the Swift
//  importer can't see — those get a static-inline wrapper here so they show
//  up as ordinary C functions in the CFFmpeg module.
//
//  Nothing in here decodes. These are demux/parse/error helpers only.
//
#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/dict.h>
#include <libavutil/pixdesc.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/hdr_dynamic_metadata.h>

// av_err2str() is a macro that returns a compound literal — invisible to
// Swift. Wrap av_strerror in a plain function instead.
static inline int cx_strerror(int errnum, char *buf, size_t buflen) {
    return av_strerror(errnum, buf, buflen);
}

// AVERROR(...) / AVERROR_EOF are macros; surface the few we branch on.
static inline int cx_averror_eof(void)   { return AVERROR_EOF; }
static inline int cx_averror_eagain(void){ return AVERROR(EAGAIN); }
static inline int cx_averror_einval(void){ return AVERROR(EINVAL); }

// Stream side-data lookup that returns the typed payload pointer + size,
// for HDR10 mastering-display / content-lr.
static inline const uint8_t *cx_stream_sid
                                          ype type,
                                                 size_t *out_size) {
    const AVPacketSideData *sd =
        av_packet_side_data_get(st->codecpar->coded_side_data,
                                st->codecp;
    if (!sd) { *out_size = 0; return NULL;
    *out_size = sd->size;
    return sd->data;
}

#endif /* CFFMPEG_SHIM_H */
