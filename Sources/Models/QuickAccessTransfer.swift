import Foundation

/// Prompts and tiles are carried over the system pasteboard as plain text URLs with distinct schemes:
/// `clipslop://prompt/<UUID>` for prompt drags from the left tree, `clipslop://tile/<UUID>` for tile reorders.
///
/// SwiftUI `.draggable` + custom-UTI Transferable doesn't reach `.dropDestination` reliably on macOS — the
/// prompt source is inside a `List` (NSTableView) that intercepts the drag, and custom UTIs declared with
/// `UTType(exportedAs:)` aren't registered with Launch Services from a bare SPM executable. Using NSString
/// with the system-known `public.utf8-plain-text` type sidesteps both. The drop site distinguishes payload
/// kind by URL prefix.
enum PromptDragPayload {
    private static let scheme = "clipslop://prompt/"

    static func encode(promptID: UUID) -> String {
        scheme + promptID.uuidString
    }

    static func decode(_ string: String) -> UUID? {
        guard string.hasPrefix(scheme) else { return nil }
        return UUID(uuidString: String(string.dropFirst(scheme.count)))
    }
}

enum TileDragPayload {
    private static let scheme = "clipslop://tile/"

    static func encode(tileID: UUID) -> String {
        scheme + tileID.uuidString
    }

    static func decode(_ string: String) -> UUID? {
        guard string.hasPrefix(scheme) else { return nil }
        return UUID(uuidString: String(string.dropFirst(scheme.count)))
    }
}
