import AppKit
@preconcurrency import ApplicationServices
import ScreenCaptureKit

enum PermissionService {

    // MARK: - Accessibility

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    /// Cached check — suitable for startup, initial state, and passive refresh.
    /// Note: this value is cached per-process by macOS and will NOT update
    /// after the user grants permission without an app restart.
    static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Live check that bypasses the per-process cache.
    /// Uses ScreenCaptureKit which queries the TCC database directly.
    /// Warning: this WILL trigger a permission prompt if not yet granted,
    /// so only call it in response to an explicit user action (e.g. button press).
    static func checkScreenRecordingLive() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Attempts to show the system screen recording prompt.
    /// `CGRequestScreenCaptureAccess()` only shows the dialog on the very first call;
    /// subsequent calls are no-ops. When it is a no-op we fall back to opening
    /// System Settings directly so the user can grant permission manually.
    static func requestScreenRecording() {
        let alreadyGranted = CGRequestScreenCaptureAccess()
        if !alreadyGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !CGPreflightScreenCaptureAccess() {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
