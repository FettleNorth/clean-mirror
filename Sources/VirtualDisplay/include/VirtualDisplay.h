// Creates a macOS virtual display: a screen that exists only in software, which
// cleanmirror captures pixel for pixel. Uses CoreGraphics' CGVirtualDisplay, an
// undocumented Apple API (the same one BetterDisplay and DeskPad use).
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/// True if this version of macOS has the virtual display API.
bool vd_available(void);

/// Creates a virtual display that looks like `width`×`height` at `refreshHz`, with Rec.709/sRGB colour
/// primaries. With `hidpi` false it is a standard screen of exactly `width`×`height` pixels; with `hidpi`
/// true it is a Retina screen drawn at twice that in each direction. Returns a handle, or NULL if it
/// couldn't be created. The display ID goes into `displayIDOut`. The display disappears when the handle
/// is destroyed or the process exits.
void *vd_create(const char *name, int width, int height, double refreshHz, bool hidpi, CGDirectDisplayID *displayIDOut);

/// Makes sure a Retina virtual display is using its double-resolution mode. Returns true if it is.
bool vd_use_hidpi_mode(CGDirectDisplayID displayID, int width, int height);

void vd_destroy(void *handle);

#ifdef __cplusplus
}
#endif
