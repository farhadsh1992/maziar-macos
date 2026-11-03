import SwiftUI
import AppKit

/// The Projects page's calendar: a month grid marking every day that has a dated, unfinished task
/// (from any project or sub-project) or a tracked conference deadline, with the matching items
/// listed beside it — each can be added to Google Calendar and/or the Calendar app.
struct ProjectsCalendarView: View {
    var onOpenProject: (Paper) -> Void

    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var settings: AppSettings

    @State private var shownMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selectedDay: Date?
    @AppStorage("maziar.projects.calendarCollapsed") private var isCollapsed = false

    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let projectTitle: String
        let date: Date
        let notes: String
        let paper: Paper
        var isTask: Bool
        /// The project's own color (or its parent's) — nil falls back to the app's button color.
        var color: Color?
    }

    private var calendar: Calendar { Calendar.current }

    private var items: [Item] {
        var result: [Item] = []
        for paper in paperStore.papers {
            for task in paper.tasks where !task.isDone {
                guard let due = task.dueDate else { continue }
                result.append(Item(
                    title: task.text, projectTitle: paper.title, date: due,
                    notes: "Task in the project \u{201c}\(paper.title)\u{201d}", paper: paper, isTask: true,
                    color: paperStore.color(of: paper)
                ))
            }
            if paper.kind == .paperSubmission, paper.decision != .rejected,
               let name = paper.conferenceName,
               let next = conferenceStore.conferences.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.nextDeadline,
               let date = next.date {
                result.append(Item(
                    title: "\(name) \u{2014} \(next.label)", projectTitle: paper.title, date: date,
                    notes: "Deadline for \u{201c}\(paper.title)\u{201d}", paper: paper, isTask: false,
                    color: paperStore.color(of: paper)
                ))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private var listedItems: [Item] {
        guard let selectedDay else { return items }
        return items.filter { calendar.isDate($0.date, inSameDayAs: selectedDay) }
    }

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Label("Calendar", systemImage: "calendar").font(.headline)
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show the calendar" : "Hide the calendar")
            if !isCollapsed {
                HStack(alignment: .top, spacing: 20) {
                    monthGrid.frame(width: 260)
                    ScrollView { itemList.frame(maxWidth: .infinity, alignment: .topLeading) }
                        .frame(maxHeight: 230)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    // MARK: Month grid

    private var monthGrid: some View {
        let days = daysInGrid()
        let today = calendar.startOfDay(for: Date())
        return VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(shownMonth.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                ForEach(weekdayHeaders(), id: \.self) { symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, today: today)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }
            if selectedDay != nil {
                Button("Show all upcoming") { selectedDay = nil }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(settings.color(for: .buttonColor))
            }
        }
    }

    private func dayCell(_ day: Date, today: Date) -> some View {
        let dayItems = items.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let overdue = day < today && !dayItems.isEmpty
        return Button {
            selectedDay = isSelected ? nil : day
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))").font(.caption)
                // One dot per distinct project color on that day (max 3); red when overdue.
                HStack(spacing: 2) {
                    ForEach(Array(dotColors(for: dayItems, overdue: overdue).enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? settings.color(for: .buttonColor).opacity(0.25) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isToday ? settings.color(for: .buttonColor) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dayItems.isEmpty ? "" : dayItems.map(\.title).joined(separator: "\n"))
    }

    private func dotColors(for dayItems: [Item], overdue: Bool) -> [Color] {
        if overdue { return [.red] }
        var seen = Set<String>()
        var colors: [Color] = []
        for item in dayItems {
            let color = item.color ?? settings.color(for: .buttonColor)
            if seen.insert(item.paper.id.uuidString).inserted, colors.count < 3 { colors.append(color) }
        }
        return colors
    }

    private func shiftMonth(_ delta: Int) {
        shownMonth = calendar.date(byAdding: .month, value: delta, to: shownMonth) ?? shownMonth
    }

    private func weekdayHeaders() -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days, padded with `nil` so the first one lands under its weekday.
    private func daysInGrid() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: shownMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: shownMonth)) else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<range.count {
            days.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        return days
    }

    // MARK: Item list

    private var itemList: some View {
        let listed = listedItems
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedDay.map { $0.formatted(date: .complete, time: .omitted) } ?? "Upcoming")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !listed.isEmpty {
                    Button {
                        addToCalendarApp(listed)
                    } label: {
                        Label("Add \(selectedDay == nil ? "All" : "These") to Calendar App", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if listed.isEmpty {
                Text(selectedDay == nil
                     ? "Nothing dated yet. Give a task a date inside its project and it shows up here."
                     : "Nothing on this day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(listed) { item in
                let overdue = item.date < calendar.startOfDay(for: Date())
                HStack(spacing: 8) {
                    Capsule()
                        .fill(item.color ?? settings.color(for: .buttonColor))
                        .frame(width: 4, height: 30)
                    Text(item.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(overdue ? Color.red : Color.secondary)
                        .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline).lineLimit(2)
                        Text(item.projectTitle).font(.caption2).foregroundStyle(item.color ?? .secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { onOpenProject(item.paper) }
                        .help("Open the project")
                    Button("Google") { openInGoogleCalendar(item) }
                        .help("Add to Google Calendar (opens it in your browser)")
                    Button("Calendar") { addToCalendarApp([item]) }
                        .help("Add to the Calendar app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// Google Calendar's "create event" link — all-day, so the end date is the day after (exclusive).
    private func openInGoogleCalendar(_ item: Item) {
        let start = Self.isoDayFormatter.string(from: item.date).replacingOccurrences(of: "-", with: "")
        let nextDay = calendar.date(byAdding: .day, value: 1, to: item.date) ?? item.date
        let end = Self.isoDayFormatter.string(from: nextDay).replacingOccurrences(of: "-", with: "")
        var components = URLComponents(string: "https://calendar.google.com/calendar/render")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: "\(item.projectTitle): \(item.title)"),
            URLQueryItem(name: "dates", value: "\(start)/\(end)"),
            URLQueryItem(name: "details", value: item.notes),
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private func addToCalendarApp(_ items: [Item]) {
        let events = items.map { (title: "\($0.projectTitle): \($0.title)", isoDate: Self.isoDayFormatter.string(from: $0.date), notes: Optional($0.notes)) }
        if let url = ICSWriter.writeAllDayEventsFile(events) { NSWorkspace.shared.open(url) }
    }
}
