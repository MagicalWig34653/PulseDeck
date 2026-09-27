import SwiftUI

/// The two primary sections (SPEC §8).
enum AppSection: String, CaseIterable, Identifiable {
    case performance
    case processes

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .performance: "Performance"
        case .processes: "Processes"
        }
    }

    var systemImage: String {
        switch self {
        case .performance: "gauge.with.dots.needle.33percent"
        case .processes: "list.bullet.rectangle"
        }
    }
}
