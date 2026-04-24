//
//  StreakCalendarView.swift
//  WakeProof
//
//  Wave 5 H3 (§12.3-H3): month-grid view showing per-day verification status.
//  Surfaces HOOK_S7_6 (continuity visual feedback): a visible trail makes a
//  "break" concrete rather than abstract. The user can see exactly which days
//  they upheld vs. broke the contract.
//
//  Cell colour legend (locked):
//  - GREEN filled circle with check: day had ≥1 VERIFIED attempt.
//  - RED/ORANGE outlined circle: day had ≥1 attempt, none verified
//    (REJECTED/RETRY/TIMEOUT/UNRESOLVED/CAPTURED). These are "you engaged
//    but didn't complete the contract" — distinct from blank because we
//    don't want the user to think the alarm didn't fire.
//  - GRAY dim: day had no attempts at all (alarm disabled, or future day
//    within the current month).
//  - "Today" marker: thin primary-tinted ring overlaid on whatever the
//    state is, so the user can anchor themselves in the grid.
//
//  Read path: the caller passes in the `[WakeAttempt]` fetched via
//  `@Query`. The view does its own per-day aggregation via the same
//  startOfDay rule as StreakService (ensuring visual consistency — if the
//  badge shows "3-day streak", the grid shows 3 green cells).
//

import SwiftUI

struct StreakCalendarView: View {
    let attempts: [WakeAttempt]

    /// Injectable for previews / snapshots; default is `.now` at render.
    /// Not @State — the month grid is a pure function of `(attempts, now,
    /// calendar)`, and we re-render on attempt changes via the parent.
    var now: Date = .now
    var calendar: Calendar = .current

    var body: some View {
        List {
            Section {
                Text(monthTitle)
                    .font(.title2.weight(.semibold))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                weekdayHeader
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                monthGrid
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                legend
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Streak")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Subviews

    private var weekdayHeader: some View {
        // Short weekday symbols ordered by the calendar's `firstWeekday`.
        // e.g. US calendar = [S, M, T, W, T, F, S] starting Sunday.
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        // LazyVGrid with 7 columns of equal flexible width. Rows = weeks.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(gridCells, id: \.id) { cell in
                cellView(for: cell)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(colour: .green, filled: true, text: "Verified — you got up")
            legendRow(colour: .orange, filled: false, text: "Alarm fired, not verified")
            legendRow(colour: .gray.opacity(0.35), filled: true, text: "No attempt")
        }
        .font(.footnote)
    }

    private func legendRow(colour: Color, filled: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if filled {
                    Circle().fill(colour)
                } else {
                    Circle().strokeBorder(colour, lineWidth: 2)
                }
            }
            .frame(width: 14, height: 14)
            Text(text).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cellView(for cell: DayCell) -> some View {
        ZStack {
            switch cell.kind {
            case .blank:
                Color.clear
            case .empty(let isFuture):
                // Past day with no attempts OR future day within this month.
                // Both render as dim gray — the distinction only matters for
                // the streak algorithm (future doesn't affect it), not for
                // the visual.
                Circle()
                    .fill(Color.gray.opacity(isFuture ? 0.15 : 0.25))
                Text(cell.dayNumberText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            case .verified:
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            case .attempted:
                Circle().strokeBorder(Color.orange, lineWidth: 2)
                Text(cell.dayNumberText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            // "Today" ring overlays whatever state the cell has.
            if cell.isToday {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .accessibilityLabel(cell.accessibilityLabel)
    }

    // MARK: - Aggregation

    /// Per-day aggregate derived from `attempts`. Mirrors StreakService's
    /// day-boundary decision: a day is VERIFIED if ANY attempt on that day
    /// is verified; ATTEMPTED if it had any non-verified attempt; EMPTY
    /// otherwise.
    private var perDayStatus: [Date: DayStatus] {
        var result: [Date: DayStatus] = [:]
        for attempt in attempts {
            let timestamp = attempt.capturedAt ?? attempt.scheduledAt
            let dayKey = calendar.startOfDay(for: timestamp)
            let isVerified = attempt.verdictEnum == .verified
            switch result[dayKey] {
            case nil:
                result[dayKey] = isVerified ? .verified : .attempted
            case .attempted:
                if isVerified { result[dayKey] = .verified }
            case .verified:
                break  // Already verified — further rows can't un-verify a day.
            }
        }
        return result
    }

    /// Compute the grid cells for the current calendar month. Each row has
    /// exactly 7 cells; leading / trailing days from adjacent months render
    /// as `.blank` so the month's 1st lands on its correct weekday column.
    private var gridCells: [DayCell] {
        let today = calendar.startOfDay(for: now)
        let statusMap = perDayStatus

        // Month range: find the first and last day of the current month.
        guard let monthInterval = calendar.dateInterval(of: .month, for: now) else {
            return []
        }
        // `monthInterval.end` is the start of the NEXT month, so the last
        // day is `end - 1 second` → startOfDay gives us the last day.
        guard let lastDayOfMonth = calendar.date(byAdding: .day, value: -1, to: monthInterval.end) else {
            return []
        }

        let firstDay = calendar.startOfDay(for: monthInterval.start)
        let firstWeekdayOfMonth = calendar.component(.weekday, from: firstDay)
        // Leading blanks before day 1: offset from the calendar's firstWeekday.
        let leadingBlanks = ((firstWeekdayOfMonth - calendar.firstWeekday) + 7) % 7

        var cells: [DayCell] = []

        // Leading blanks (previous month's tail)
        for i in 0..<leadingBlanks {
            cells.append(DayCell(id: "blank-leading-\(i)", kind: .blank, dayNumberText: "", isToday: false, accessibilityLabel: ""))
        }

        // Days of the current month
        var cursor = firstDay
        while cursor <= lastDayOfMonth {
            let dayNumber = calendar.component(.day, from: cursor)
            let isFuture = cursor > today
            let isToday = calendar.isDate(cursor, inSameDayAs: today)
            let status = statusMap[cursor]

            let kind: DayCell.Kind
            switch status {
            case .verified:
                kind = .verified
            case .attempted:
                kind = .attempted
            case nil:
                kind = .empty(isFuture: isFuture)
            }

            cells.append(DayCell(
                id: "day-\(dayNumber)",
                kind: kind,
                dayNumberText: "\(dayNumber)",
                isToday: isToday,
                accessibilityLabel: accessibilityLabel(for: cursor, dayNumber: dayNumber, status: status, isToday: isToday, isFuture: isFuture)
            ))

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }

        // Trailing blanks to round the last row to 7 cells
        let trailingBlanks = (7 - (cells.count % 7)) % 7
        for i in 0..<trailingBlanks {
            cells.append(DayCell(id: "blank-trailing-\(i)", kind: .blank, dayNumberText: "", isToday: false, accessibilityLabel: ""))
        }
        return cells
    }

    // MARK: - Titles / labels

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.dateFormat = "LLLL yyyy"  // e.g. "April 2026"
        return formatter.string(from: now)
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols  // e.g. [Sun, Mon, ...]
        // Rotate so `firstWeekday` comes first. firstWeekday is 1-indexed.
        let startIndex = calendar.firstWeekday - 1
        guard startIndex < symbols.count else { return symbols }
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }

    private func accessibilityLabel(
        for date: Date,
        dayNumber: Int,
        status: DayStatus?,
        isToday: Bool,
        isFuture: Bool
    ) -> String {
        let prefix = isToday ? "Today, " : ""
        let day = "day \(dayNumber)"
        let state: String
        switch status {
        case .verified: state = "verified"
        case .attempted: state = "alarm fired, not verified"
        case nil: state = isFuture ? "future day, no attempt" : "no attempt"
        }
        return "\(prefix)\(day), \(state)."
    }

    // MARK: - Types

    private enum DayStatus {
        case verified
        case attempted
    }

    private struct DayCell {
        enum Kind {
            case blank
            case empty(isFuture: Bool)
            case verified
            case attempted
        }

        let id: String
        let kind: Kind
        let dayNumberText: String
        let isToday: Bool
        let accessibilityLabel: String
    }
}
