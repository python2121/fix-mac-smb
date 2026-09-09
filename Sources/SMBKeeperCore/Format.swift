import Foundation

/// Display formatting shared by the panel and the CLI.
public enum Format {
    /// SI byte sizes: "7.4 TB", "512 B". Decimal units, matching what Finder
    /// and every NAS admin page show.
    public static func bytes(_ n: Double) -> String {
        var value = n
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if abs(value) < 1000 {
                return unit == "B"
                    ? String(format: "%.0f B", value)
                    : String(format: "%.1f %@", value, unit)
            }
            value /= 1000
        }
        return String(format: "%.1f PB", value)
    }

    public static func bytes(_ n: UInt64) -> String { bytes(Double(n)) }

    /// Probe latency, kept short: "30 ms", "1.2 s".
    public static func latency(milliseconds ms: Double) -> String {
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        return String(format: "%.1f s", ms / 1000)
    }

    /// Coarse "how long ago", for a last-seen-healthy timestamp.
    public static func relative(_ then: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(then)
        if seconds < 0 { return "just now" }
        if seconds < 45 { return "just now" }
        if seconds < 90 { return "1m ago" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "\(hours)h ago" }
        let days = Int((seconds / 86400).rounded())
        return "\(days)d ago"
    }

    /// Wall-clock time of day, for tooltips.
    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
