import SwiftUI

/// The primary sections (SPEC §8), plus Containers (local Docker containers, e.g. via Colima)
/// USB (the USB device tree), Virtual Machines (Colima, Lima, Tart, UTM …) and Traffic (layer 3/4
/// destinations).
enum AppSection: String, CaseIterable, Identifiable {
    case performance
    case processes
    case containers
    case usb
    case machines
    case traffic

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .performance: "Performance"
        case .processes: "Processes"
        case .containers: "Containers"
        case .usb: "USB"
        case .machines: "Virtual Machines"
        case .traffic: "Traffic"
        }
    }

    var systemImage: String {
        switch self {
        case .performance: "gauge.with.dots.needle.33percent"
        case .processes: "list.bullet.rectangle"
        case .containers: "shippingbox"
        case .usb: "cable.connector.horizontal"
        case .machines: "macwindow.on.rectangle"
        case .traffic: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}
