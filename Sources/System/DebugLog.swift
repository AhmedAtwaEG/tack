import Foundation
import os

/// Opt-in diagnostics for "why didn't a note show up here?". Off unless
///   defaults write com.tack.app debugPaths -bool YES
/// then watch with: log stream --predicate 'subsystem == "com.tack.app"'
///
/// Messages are logged as public on purpose: NSLog's arguments show as `<private>` on a Mac
/// with default privacy settings, which made the log useless for exactly this job. They can
/// name window titles and URLs, which is why the whole thing stays opt-in.
enum DebugLog {
    private static let logger = Logger(subsystem: "com.tack.app", category: "debug")

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "debugPaths") }

    static func note(_ message: @autoclosure () -> String) {
        guard isOn else { return }
        let text = message()
        logger.notice("\(text, privacy: .public)")
    }
}
