import Foundation
import CoreGraphics

public enum MirrorError: LocalizedError {
    case needsScreenRecording
    case box(String)
    case virtualScreenUnavailable
    case virtualScreenFailed
    case displayNotFound
    case capture(String)

    public var errorDescription: String? {
        switch self {
        case .needsScreenRecording:
            return "Needs Screen Recording permission."
        case .box(let message):
            return message
        case .virtualScreenUnavailable:
            return "This version of macOS doesn't offer virtual screens any more. Mirror the main display instead."
        case .virtualScreenFailed:
            return "Couldn't create the Clean Mirror screen. Is cleanmirror already running somewhere else?"
        case .displayNotFound:
            return "Couldn't find the screen to capture."
        case .capture(let message):
            return "Screen capture failed: \(message)"
        }
    }

    /// True when the box is held by another app (Final Cut, Media Express, Resolve...).
    public var isBoxBusy: Bool {
        if case .box(let message) = self { return message.contains("another app") }
        return false
    }
}

/// Whether this app may capture the screen. Doesn't ask.
public func screenRecordingAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

/// Asks macOS for Screen Recording permission (shows the system prompt the first time).
@discardableResult
public func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }
