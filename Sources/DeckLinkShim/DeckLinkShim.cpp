#include "DeckLinkShim.h"
#include "sdk/DeckLinkAPI.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Frames queued in the box ahead of what's on screen: more is steadier, fewer is lower latency.
// Chosen per output in dl_output_open (2-8).

// We hand the box 8-bit YUV 4:2:2 ('2vuy'), which is what it sends down HDMI and SDI anyway,
// so the driver has nothing left to convert. The UltraStudio Monitor 3G only takes RGB at 25p/30p.
static const BMDPixelFormat kOutputFormat = bmdFormat8BitYUV;

// Rec.709, video range (Y' 16-235, CbCr 16-240), clamped to legal values. A fixed formula, no dithering.
static const vImage_ARGBToYpCbCr *conversionInfo() {
    static vImage_ARGBToYpCbCr info;
    static bool ready = [] {
        vImage_YpCbCrPixelRange range = { 16, 128, 235, 240, 235, 16, 240, 16 };
        return vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
                                                             kvImageARGB8888, kvImage422CbYpCrYp8, kvImageNoFlags) == kvImageNoError;
    }();
    return ready ? &info : nullptr;
}

extern "C" bool dl_convert_bgra_to_2vuy(const uint8_t *src, size_t srcRowBytes, uint8_t *dst, size_t dstRowBytes,
                                        int width, int height) {
    const vImage_ARGBToYpCbCr *info = conversionInfo();
    if (!info) return false;
    vImage_Buffer in = { (void *)src, (vImagePixelCount)height, (vImagePixelCount)width, srcRowBytes };
    vImage_Buffer out = { dst, (vImagePixelCount)height, (vImagePixelCount)width, dstRowBytes };
    const uint8_t bgraToARGB[4] = { 3, 2, 1, 0 };
    return vImageConvert_ARGB8888To422CbYpCrYp8(&in, &out, info, bgraToARGB, kvImageNoFlags) == kvImageNoError;
}

static std::string toStd(CFStringRef s) {
    if (!s) return "";
    char buf[256];
    if (CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8)) return buf;
    return "";
}

static void setText(char *dst, int len, const std::string &text) {
    if (dst && len > 0) snprintf(dst, (size_t)len, "%s", text.c_str());
}

static bool sameIID(REFIID a, REFIID b) { return memcmp(&a, &b, sizeof(REFIID)) == 0; }

static BMDDisplayMode modeForFPS(int fps) {
    switch (fps) {
        case 25: return bmdModeHD1080p25;
        case 30: return bmdModeHD1080p30;
        case 50: return bmdModeHD1080p50;
        case 60: return bmdModeHD1080p6000;
        default: return 0;
    }
}

static std::string deviceName(IDeckLink *deckLink) {
    CFStringRef name = nullptr;
    if (deckLink->GetDisplayName(&name) != S_OK || !name) return "Unknown device";
    std::string result = toStd(name);
    CFRelease(name);
    return result;
}

static bool supports(IDeckLinkOutput *output, BMDDisplayMode mode, BMDPixelFormat format) {
    bool supported = false;
    HRESULT r = output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, mode, format,
                                             bmdNoVideoOutputConversion, bmdSupportedVideoModeDefault,
                                             nullptr, &supported);
    return r == S_OK && supported;
}

struct Slot {
    IDeckLinkMutableVideoFrame *frame = nullptr;
    uint64_t generation = 0;   // which captured frame's pixels this output frame holds
};

class OutputCallback;

struct DLOutput {
    IDeckLink *deckLink = nullptr;
    IDeckLinkOutput *output = nullptr;
    OutputCallback *callback = nullptr;
    std::string name;

    long width = 1920, height = 1080;
    int32_t rowBytes = 1920 * 4;
    BMDTimeValue frameDuration = 0;
    BMDTimeScale timeScale = 0;

    std::vector<Slot> slots;
    std::mutex scheduleLock;
    uint64_t nextFrameNumber = 0;

    std::mutex latestLock;
    CVPixelBufferRef latest = nullptr;
    uint64_t latestGeneration = 0;

    std::atomic<bool> running{false};
    std::atomic<uint64_t> scheduled{0}, completed{0}, late{0}, dropped{0}, copies{0};
};

static void scheduleSlot(DLOutput *o, Slot &slot);

class OutputCallback : public IDeckLinkVideoOutputCallback {
public:
    explicit OutputCallback(DLOutput *owner) : owner_(owner) {}

    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame, BMDOutputFrameCompletionResult result) override {
        switch (result) {
            case bmdOutputFrameCompleted: owner_->completed++; break;
            case bmdOutputFrameDisplayedLate: owner_->late++; break;
            case bmdOutputFrameDropped: owner_->dropped++; break;
            case bmdOutputFrameFlushed: return S_OK;
            default: break;
        }
        if (!owner_->running) return S_OK;
        for (Slot &slot : owner_->slots) {
            if (slot.frame == completedFrame) {
                {
                    std::lock_guard<std::mutex> g(owner_->scheduleLock);
                    // Running behind: skip a frame slot so the queue catches up with the clock.
                    if (result == bmdOutputFrameDisplayedLate || result == bmdOutputFrameDropped) owner_->nextFrameNumber++;
                }
                scheduleSlot(owner_, slot);
                break;
            }
        }
        return S_OK;
    }

    HRESULT ScheduledPlaybackHasStopped() override { return S_OK; }

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || sameIID(iid, IID_IDeckLinkVideoOutputCallback)) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refCount_; }
    ULONG Release() override {
        ULONG r = --refCount_;
        if (r == 0) delete this;
        return r;
    }

private:
    DLOutput *owner_;
    std::atomic<ULONG> refCount_{1};
};

/// Copies the newest captured frame into this output frame, unless it already holds it.
static void fillSlot(DLOutput *o, Slot &slot) {
    CVPixelBufferRef pb = nullptr;
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> g(o->latestLock);
        if (o->latest) {
            pb = CVPixelBufferRetain(o->latest);
            generation = o->latestGeneration;
        }
    }
    if (!pb) return;
    if (generation != slot.generation) {
        IDeckLinkVideoBuffer *buffer = nullptr;
        if (slot.frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) == S_OK) {
            if (buffer->StartAccess(bmdBufferAccessWrite) == S_OK) {
                void *dst = nullptr;
                if (buffer->GetBytes(&dst) == S_OK && dst &&
                    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
                    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
                    size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pb);
                    size_t w = std::min((size_t)o->width, CVPixelBufferGetWidth(pb));
                    size_t h = std::min((size_t)o->height, CVPixelBufferGetHeight(pb));
                    if (src && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA &&
                        dl_convert_bgra_to_2vuy(src, srcRowBytes, (uint8_t *)dst, (size_t)o->rowBytes, (int)w, (int)h)) {
                        slot.generation = generation;
                        o->copies++;
                    }
                    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                }
                buffer->EndAccess(bmdBufferAccessWrite);
            }
            buffer->Release();
        }
    }
    CVPixelBufferRelease(pb);
}

static void scheduleSlot(DLOutput *o, Slot &slot) {
    fillSlot(o, slot);
    std::lock_guard<std::mutex> g(o->scheduleLock);
    HRESULT r = o->output->ScheduleVideoFrame(slot.frame, (BMDTimeValue)o->nextFrameNumber * o->frameDuration,
                                              o->frameDuration, o->timeScale);
    if (r == S_OK) {
        o->nextFrameNumber++;
        o->scheduled++;
    }
}

static void clearToBlack(DLOutput *o, IDeckLinkMutableVideoFrame *frame) {
    IDeckLinkVideoBuffer *buffer = nullptr;
    if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) != S_OK) return;
    if (buffer->StartAccess(bmdBufferAccessWrite) == S_OK) {
        void *dst = nullptr;
        if (buffer->GetBytes(&dst) == S_OK && dst) {
            uint8_t *px = (uint8_t *)dst;
            size_t bytes = (size_t)o->rowBytes * (size_t)o->height;
            const uint8_t black[4] = { 128, 16, 128, 16 };   // Cb Y' Cr Y': video-range black
            for (size_t i = 0; i < bytes; i++) px[i] = black[i % 4];
        }
        buffer->EndAccess(bmdBufferAccessWrite);
    }
    buffer->Release();
}

static void closeOutput(DLOutput *o) {
    if (!o) return;
    for (Slot &slot : o->slots)
        if (slot.frame) slot.frame->Release();
    if (o->output) {
        o->output->SetScheduledFrameCompletionCallback(nullptr);
        o->output->DisableVideoOutput();
        o->output->Release();
    }
    if (o->callback) o->callback->Release();
    if (o->deckLink) o->deckLink->Release();
    if (o->latest) CVPixelBufferRelease(o->latest);
    delete o;
}

extern "C" int dl_list_devices(char *buf, int bufLen) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        setText(buf, bufLen, "");
        return -1;
    }
    std::string text;
    int count = 0;
    IDeckLink *deckLink = nullptr;
    while (iterator->Next(&deckLink) == S_OK) {
        count++;
        text += "  " + deviceName(deckLink) + ": ";
        IDeckLinkOutput *output = nullptr;
        if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) == S_OK) {
            std::string modes;
            const int rates[] = {25, 30, 50, 60};
            for (int fps : rates) {
                if (supports(output, modeForFPS(fps), kOutputFormat)) {
                    if (!modes.empty()) modes += ", ";
                    modes += "1080p" + std::to_string(fps);
                }
            }
            text += modes.empty() ? "output, but no 1080p modes in 8-bit YUV" : modes;
            output->Release();
        } else {
            text += "no video output";
        }
        text += "\n";
        deckLink->Release();
    }
    iterator->Release();
    setText(buf, bufLen, text);
    return count;
}

extern "C" DLOutput *dl_output_open(int fps, int queuedFrames, char *err, int errLen, char *nameOut, int nameLen) {
    if (queuedFrames < 2) queuedFrames = 2;
    if (queuedFrames > 8) queuedFrames = 8;
    BMDDisplayMode mode = modeForFPS(fps);
    if (!mode) {
        setText(err, errLen, "Frame rate must be 25, 30, 50 or 60.");
        return nullptr;
    }
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        setText(err, errLen, "The Blackmagic Desktop Video driver isn't installed (or couldn't be loaded).");
        return nullptr;
    }

    DLOutput *o = new DLOutput();
    std::string reasons;
    IDeckLink *deckLink = nullptr;
    while (iterator->Next(&deckLink) == S_OK) {
        std::string name = deviceName(deckLink);
        IDeckLinkOutput *output = nullptr;
        if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) == S_OK) {
            if (supports(output, mode, kOutputFormat)) {
                o->deckLink = deckLink;
                o->output = output;
                o->name = name;
                break;
            }
            reasons += name + " can't output 1080p" + std::to_string(fps) + " in 8-bit YUV. ";
            output->Release();
        } else {
            reasons += name + " has no video output. ";
        }
        deckLink->Release();
    }
    iterator->Release();

    if (!o->output) {
        setText(err, errLen, reasons.empty()
            ? "No Blackmagic device found. Check the UltraStudio is plugged in and shows up in Desktop Video Setup."
            : reasons);
        closeOutput(o);
        return nullptr;
    }
    setText(nameOut, nameLen, o->name);

    IDeckLinkDisplayMode *displayMode = nullptr;
    if (o->output->GetDisplayMode(mode, &displayMode) != S_OK || !displayMode) {
        setText(err, errLen, "Couldn't read the 1080p display mode from the device.");
        closeOutput(o);
        return nullptr;
    }
    o->width = displayMode->GetWidth();
    o->height = displayMode->GetHeight();
    displayMode->GetFrameRate(&o->frameDuration, &o->timeScale);
    displayMode->Release();
    o->output->RowBytesForPixelFormat(kOutputFormat, (int32_t)o->width, &o->rowBytes);

    if (!conversionInfo()) {
        setText(err, errLen, "Couldn't set up the RGB to YUV conversion.");
        closeOutput(o);
        return nullptr;
    }

    if (o->output->EnableVideoOutput(mode, bmdVideoOutputFlagDefault) != S_OK) {
        setText(err, errLen, "Couldn't turn on the output. Is another app (Final Cut, Media Express, Resolve) using the box? Quit it and try again.");
        o->output->Release();
        o->output = nullptr;
        closeOutput(o);
        return nullptr;
    }

    for (int i = 0; i < queuedFrames; i++) {
        IDeckLinkMutableVideoFrame *frame = nullptr;
        if (o->output->CreateVideoFrame((int32_t)o->width, (int32_t)o->height, o->rowBytes, kOutputFormat,
                                        bmdFrameFlagDefault, &frame) != S_OK || !frame) {
            setText(err, errLen, "Couldn't create output frames.");
            closeOutput(o);
            return nullptr;
        }
        clearToBlack(o, frame);
        Slot slot;
        slot.frame = frame;
        o->slots.push_back(slot);
    }

    o->callback = new OutputCallback(o);
    if (o->output->SetScheduledFrameCompletionCallback(o->callback) != S_OK) {
        setText(err, errLen, "Couldn't register for frame callbacks.");
        closeOutput(o);
        return nullptr;
    }
    return o;
}

extern "C" void dl_output_submit(DLOutput *o, CVPixelBufferRef pixelBuffer) {
    if (!o || !pixelBuffer) return;
    CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRef old = nullptr;
    {
        std::lock_guard<std::mutex> g(o->latestLock);
        old = o->latest;
        o->latest = pixelBuffer;
        o->latestGeneration++;
    }
    if (old) CVPixelBufferRelease(old);
}

extern "C" bool dl_output_start(DLOutput *o, char *err, int errLen) {
    if (!o) return false;
    o->running = true;
    for (Slot &slot : o->slots) scheduleSlot(o, slot);
    if (o->output->StartScheduledPlayback(0, o->timeScale, 1.0) != S_OK) {
        o->running = false;
        setText(err, errLen, "Couldn't start playback on the box.");
        return false;
    }
    return true;
}

extern "C" void dl_output_get_stats(DLOutput *o, DLOutputStats *stats) {
    if (!o || !stats) return;
    stats->scheduled = o->scheduled;
    stats->completed = o->completed;
    stats->late = o->late;
    stats->dropped = o->dropped;
    stats->copies = o->copies;
    uint32_t buffered = 0;
    o->output->GetBufferedVideoFrameCount(&buffered);
    stats->buffered = buffered;
}

extern "C" void dl_output_stop_and_close(DLOutput *o) {
    if (!o) return;
    o->running = false;
    BMDTimeValue stoppedAt = 0;
    o->output->StopScheduledPlayback(0, &stoppedAt, o->timeScale);
    for (int i = 0; i < 100; i++) {
        bool active = false;
        if (o->output->IsScheduledPlaybackRunning(&active) != S_OK || !active) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    closeOutput(o);
}
