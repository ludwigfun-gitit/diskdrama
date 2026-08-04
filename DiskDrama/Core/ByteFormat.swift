import Foundation

/// Byte formatting for everything the user reads.
///
/// macOS Storage, Finder and About This Mac all use decimal SI units
/// (1 GB = 10^9 bytes), not binary GiB. DiskDrama matches them — a cleanup
/// advisor that disagrees with Finder about how big a folder is has already
/// lost the user's trust before it gives any advice.
enum ByteFormat {

    /// Compact form for the menubar and dense table cells: `42.3 GB`, `817 MB`.
    static func compact(_ bytes: Int64) -> String {
        let magnitude = abs(bytes)
        let sign = bytes < 0 ? "−" : ""
        switch magnitude {
        case 1_000_000_000...:
            return sign + String(format: "%.1f GB", Double(magnitude) / 1_000_000_000)
        case 1_000_000...:
            return sign + String(format: "%.0f MB", Double(magnitude) / 1_000_000)
        case 1_000...:
            return sign + String(format: "%.0f KB", Double(magnitude) / 1_000)
        default:
            return sign + "\(magnitude) bytes"
        }
    }

    /// Two-decimal form for places where precision matters — the verify-reclaimed
    /// readout (F24), where rounding to one decimal can hide a real discrepancy.
    static func precise(_ bytes: Int64) -> String {
        let magnitude = abs(bytes)
        let sign = bytes < 0 ? "−" : ""
        switch magnitude {
        case 1_000_000_000...:
            return sign + String(format: "%.2f GB", Double(magnitude) / 1_000_000_000)
        case 1_000_000...:
            return sign + String(format: "%.1f MB", Double(magnitude) / 1_000_000)
        default:
            return sign + String(format: "%.0f KB", Double(magnitude) / 1_000)
        }
    }

    /// Signed form for delta views (F20), where direction is the point.
    static func delta(_ bytes: Int64) -> String {
        bytes >= 0 ? "+" + compact(bytes) : compact(bytes)
    }

    /// Entry and file counts: `12,991`.
    ///
    /// Grouped with a comma rather than via `Int.formatted()`, which uses the
    /// user's locale separator. On a European locale that renders 12991 as
    /// "12.991" — sitting directly beside "6.9 GB", where the same dot is a
    /// decimal point, because every size here is formatted non-locally to match
    /// Finder. One separator meaning two different things in one line of text is
    /// worse than not localizing at all.
    /// A file count with its noun, pluralised. Every caller was writing
    /// `"\(count(n)) files"`, which renders "1 files" — small, but it is the
    /// kind of detail that makes an app feel unattended.
    static func files(_ value: Int) -> String {
        "\(count(value)) \(value == 1 ? "file" : "files")"
    }

    static func count(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return (value < 0 ? "−" : "") + String(grouped.reversed())
    }
}
