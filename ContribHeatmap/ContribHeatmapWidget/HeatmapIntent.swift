// HeatmapIntent.swift
// ContribHeatmapWidget

import AppIntents
import WidgetKit

enum HeatmapSource: String, AppEnum, CaseIterable, Sendable {
    case githubContributions
    case runningActivity

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Heatmap Source")

    static let caseDisplayRepresentations: [HeatmapSource: DisplayRepresentation] = [
        .githubContributions: DisplayRepresentation(title: "GitHub Contributions"),
        .runningActivity: DisplayRepresentation(title: "Running Activity")
    ]
}

struct HeatmapConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "GitHeatmap"
    static let description = IntentDescription("Choose which activity heatmap to display.")

    @Parameter(title: "Data Source", default: .githubContributions)
    var source: HeatmapSource

    @Parameter(title: "GitHub Username", default: "Jeetchavan02")
    var username: String

    init() {
        self.source = .githubContributions
        self.username = "Jeetchavan02"
    }

    init(username: String, source: HeatmapSource = .githubContributions) {
        self.source = source
        self.username = username
    }
}
