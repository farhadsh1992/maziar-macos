import Foundation

/// Minimal `.ics` (iCalendar) file writer — handed to `NSWorkspace.shared.open`, which routes it
/// straight to Calendar.app's own "Add Event" confirmation sheet. Simpler and more robust than
/// talking to EventKit directly for this: no calendar-access permission prompt/entitlement needed
/// at all, and the user gets Calendar's own real UI to review/edit before it's actually added.
enum ICSWriter {
    /// `isoDate` accepts either a bare date ("2026-03-05") or a full ISO 8601 date-time
    /// ("2026-03-05T14:00:00Z") — produces an all-day event for the former, a timed event for the
    /// latter. Returns nil if `isoDate` doesn't parse as either.
    static func writeEventFile(title: String, isoDate: String, location: String?, notes: String?) -> URL? {
        let dtStartLine: String
        if isoDate.contains("T") {
            guard let date = parseISODateTime(isoDate) else { return nil }
            dtStartLine = "DTSTART:\(timestampFormatter.string(from: date))"
        } else {
            let compact = isoDate.replacingOccurrences(of: "-", with: "")
            guard compact.count == 8, Int(compact) != nil else { return nil }
            dtStartLine = "DTSTART;VALUE=DATE:\(compact)"
        }

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Maziar//CV AutoFill//EN",
            "BEGIN:VEVENT",
            "UID:\(UUID().uuidString)",
            "DTSTAMP:\(timestampFormatter.string(from: Date()))",
            dtStartLine,
            "SUMMARY:\(escape(title))",
        ]
        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("LOCATION:\(escape(location))")
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("DESCRIPTION:\(escape(notes))")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        let content = lines.joined(separator: "\r\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maziar-event-\(UUID().uuidString).ics")
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }

    private static func parseISODateTime(_ iso: String) -> Date? {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime]
        if let date = strict.date(from: iso) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }

        if !iso.hasSuffix("Z") {
            return strict.date(from: iso + "Z")
        }
        return nil
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
