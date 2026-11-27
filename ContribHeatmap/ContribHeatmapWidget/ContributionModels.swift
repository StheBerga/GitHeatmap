// ContributionModels.swift
// ContribHeatmapWidget
//
// API: https://github-contributions-api.jogruber.de/v4/{username}
// Real schema (verified 2026-10-17):
//   { "total": { "2026": 0, ... }, "contributions": [{ "date": "2026-01-01", "count": 0, "level": 0 }] }
//
// Note: The original deno.dev API is sunset (July 2026). We use the jogruber.de API instead.
// The API's `level` field is ignored in favour of our own quartile-based level mapping.

import Foundation

// MARK: - API Response Models

/// Top-level API response. Unknown keys are silently ignored via `unknownKeys`.
struct APIResponse: Decodable, Sendable {
    let contributions: [APIContributionDay]

    // We don't decode `total` – we compute our own window total.
    private enum CodingKeys: String, CodingKey {
        case contributions
    }
}

/// One entry in the flat `contributions` array.
struct APIContributionDay: Decodable, Sendable {
    let date: String            // "yyyy-MM-dd"
    let count: Int

    // `level` is intentionally NOT decoded; we compute our own quartile levels.
    private enum CodingKeys: String, CodingKey {
        case date, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date  = try c.decode(String.self, forKey: .date)
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0   // default to 0 on missing
    }
}

// MARK: - Domain Models

/// Contribution level 0 (none) … 4 (highest), computed from quartiles.
enum ContributionLevel: Int, Sendable, CaseIterable {
    case none  = 0
    case low   = 1
    case medium = 2
    case high  = 3
    case max   = 4
}

/// A single day with its resolved contribution data.
struct ContributionDay: Sendable, Identifiable {
    let id: String          // ISO date string – stable & unique
    let date: Date
    let count: Int
    let level: ContributionLevel
    /// `true` for future days in the current week – rendered as invisible placeholders.
    let isFuture: Bool

    init(date: Date, count: Int, level: ContributionLevel, isFuture: Bool = false) {
        let formatter = ContributionDay.isoFormatter
        self.id = formatter.string(from: date)
        self.date = date
        self.count = count
        self.level = level
        self.isFuture = isFuture
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.calendar   = Calendar(identifier: .gregorian)
        f.timeZone   = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// A week column (Sun…Sat) in the heatmap grid.
struct ContributionWeek: Sendable, Identifiable {
    let id: Int             // column index
    let days: [ContributionDay?]   // 7 slots; nil = invisible padding (never rendered)

    init(id: Int, days: [ContributionDay?]) {
        precondition(days.count == 7)
        self.id = id
        self.days = days
    }
}

// MARK: - Private Running Activity JSON

/// Metadata describing the rolling date window in activity_data.json.
struct ActivityDataWindow: Codable, Sendable {
    let start: String
    let end: String
}

/// One daily moving-time value. The source JSON stores hours as a decimal.
struct ActivityDataDay: Codable, Sendable {
    let date: String
    let movingTime: Double

    private enum CodingKeys: String, CodingKey {
        case date
        case movingTime = "moving_time"
    }
}

/// Versioned document exported by StheBerga/activity-heatmap.
struct ActivityDataDocument: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let timezone: String
    let window: ActivityDataWindow
    let days: [ActivityDataDay]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case timezone
        case window
        case days
    }

    /// Enforces the contract produced by the private activity-data pipeline.
    func validate() throws {
        guard schemaVersion == 1 else {
            throw ActivityDataValidationError.unsupportedSchema(schemaVersion)
        }
        guard timezone == "Europe/Rome" else {
            throw ActivityDataValidationError.invalidTimezone(timezone)
        }
        let timestampParser = ISO8601DateFormatter()
        timestampParser.formatOptions = [.withInternetDateTime]
        let fractionalTimestampParser = ISO8601DateFormatter()
        fractionalTimestampParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard timestampParser.date(from: generatedAt) != nil
                || fractionalTimestampParser.date(from: generatedAt) != nil else {
            throw ActivityDataValidationError.invalidGeneratedAt
        }
        guard days.count == 365 else {
            throw ActivityDataValidationError.invalidDayCount(days.count)
        }

        let parser = Self.makeDateParser()
        guard let start = parser.date(from: window.start),
              parser.string(from: start) == window.start,
              let end = parser.date(from: window.end),
              parser.string(from: end) == window.end else {
            throw ActivityDataValidationError.invalidWindow
        }

        guard days.first?.date == window.start, days.last?.date == window.end else {
            throw ActivityDataValidationError.windowDoesNotMatchDays
        }

        var previousDate: Date?
        let calendar = HeatmapGridBuilder.calendar
        for day in days {
            guard let date = parser.date(from: day.date),
                  parser.string(from: date) == day.date else {
                throw ActivityDataValidationError.invalidDate(day.date)
            }
            if let previousDate {
                guard let expectedDate = calendar.date(byAdding: .day, value: 1, to: previousDate),
                      parser.string(from: expectedDate) == day.date else {
                    throw ActivityDataValidationError.nonConsecutiveDates
                }
            }
            previousDate = date

            let movingTimeInSeconds = (day.movingTime * 3_600).rounded()
            guard day.movingTime.isFinite,
                  day.movingTime >= 0,
                  movingTimeInSeconds.isFinite,
                  movingTimeInSeconds < Double(Int.max) else {
                throw ActivityDataValidationError.invalidMovingTime(day.date)
            }
        }

        guard let first = parser.date(from: window.start),
              let last = parser.date(from: window.end),
              let expectedEnd = calendar.date(byAdding: .day, value: 364, to: first),
              calendar.isDate(expectedEnd, inSameDayAs: last) else {
            throw ActivityDataValidationError.invalidWindowLength
        }
    }

    /// Converts decimal hours to seconds so the existing heatmap level algorithm
    /// can be reused without changing the GitHub contribution source.
    func contributionDays() throws -> [ContributionDay] {
        try validate()
        let parser = Self.makeDateParser()
        return days.compactMap { day in
            guard let date = parser.date(from: day.date) else { return nil }
            let seconds = Int((day.movingTime * 3_600).rounded())
            return ContributionDay(date: date, count: seconds, level: .none)
        }
    }

    private static func makeDateParser() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

enum ActivityDataValidationError: LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case invalidTimezone(String)
    case invalidGeneratedAt
    case invalidDayCount(Int)
    case invalidWindow
    case windowDoesNotMatchDays
    case invalidDate(String)
    case nonConsecutiveDates
    case invalidMovingTime(String)
    case invalidWindowLength

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported activity JSON schema version: \(version)."
        case .invalidTimezone(let timezone):
            return "Unexpected activity data timezone: \(timezone)."
        case .invalidGeneratedAt:
            return "The activity JSON generated_at timestamp is invalid."
        case .invalidDayCount(let count):
            return "Expected 365 activity dates, found \(count)."
        case .invalidWindow:
            return "The activity JSON date window is invalid."
        case .windowDoesNotMatchDays:
            return "The activity JSON dates do not match its declared window."
        case .invalidDate(let date):
            return "Invalid activity date: \(date)."
        case .nonConsecutiveDates:
            return "Activity JSON dates must be consecutive calendar days."
        case .invalidMovingTime(let date):
            return "Invalid moving_time value for \(date)."
        case .invalidWindowLength:
            return "The activity JSON window must span exactly 365 days."
        }
    }
}

// MARK: - Errors

enum ContributionError: LocalizedError, Sendable {
    case invalidUsername
    case network(Error)
    case badStatus(Int)
    case decoding(Error)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidUsername:   return "Invalid username"
        case .network(let e):   return "Network error: \(e.localizedDescription)"
        case .badStatus(let c): return "HTTP \(c)"
        case .decoding(let e):  return "Decoding error: \(e.localizedDescription)"
        case .empty:             return "No contributions found"
        }
    }
}
