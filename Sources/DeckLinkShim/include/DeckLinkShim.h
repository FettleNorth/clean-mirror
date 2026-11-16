// Plain C interface to a Blackmagic DeckLink / UltraStudio output, so Swift can use it.
// The DeckLink API itself is C++ and lives behind this in DeckLinkShim.cpp.
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DLOutput DLOutput;

typedef struct {
    uint64_t scheduled;   // frames handed to the box
    uint64_t completed;   // frames the box showed on time
    uint64_t late;        // frames the box showed late
    uint64_t dropped;     // frames the box dropped
    uint64_t copies;      // times new screen pixels were copied into an output frame
    uint32_t buffered;    // frames currently queued in the box
} DLOutputStats;

/// Writes one line per Blackmagic device into `buf`, with the 1080p modes it can output.
/// Returns the number of devices, or -1 if the Desktop Video driver isn't installed.
int dl_list_devices(char *buf, int bufLen);

/// Converts 8-bit BGRA to 8-bit YUV 4:2:2 ('2vuy': Cb Y' Cr Y'), Rec.709 video range. Width must be even.
bool dl_convert_bgra_to_2vuy(const uint8_t *src, size_t srcRowBytes, uint8_t *dst, size_t dstRowBytes,
                             int width, int height);

/// Opens the first device that can output 1080p at `fps` (25, 30, 50 or 60) in 8-bit YUV, with
/// `queuedFrames` (2-8) frames waiting in the box. Returns NULL and writes the reason into `err` if it can't.
DLOutput *dl_output_open(int fps, int queuedFrames, char *err, int errLen, char *nameOut, int nameLen);

/// Hands over the newest captured frame (1920x1080 BGRA; converted to YUV on the way out). The output keeps it until a newer one arrives
/// and shows it on every output frame in the meantime.
void dl_output_submit(DLOutput *output, CVPixelBufferRef pixelBuffer);

/// Starts steady playback on the box's own clock.
bool dl_output_start(DLOutput *output, char *err, int errLen);

void dl_output_get_stats(DLOutput *output, DLOutputStats *stats);

/// Stops playback, turns the output off and frees everything.
void dl_output_stop_and_close(DLOutput *output);

#ifdef __cplusplus
}
#endif
