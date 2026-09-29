import SwiftUI

/// The primary sections (SPEC §8), plus Containers (local Docker containers, e.g. via Colima).
enum AppSection: String, CaseIterable, Identifiable {
    case performance
    case processes
    case containers

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .performance: "Performance"
        case .processes: "Processes"
        case .containers: "Containers"
        }
    }

    var systemImage: String {
        switch self {
        case .performance: "gauge.with.dots.needle.33percent"
        case .processes: "list.bullet.rectangle"
        case .containers: "shippingbox"
        }
    }
}
