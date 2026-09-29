import PulseDeckCore
import SwiftUI

/// Performance categories (SPEC §10).
enum ResourceCategory: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case disks
    case network
    case gpu
    case energy
    case thermals

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disks: "Disks"
        case .network: "Network Interfaces"
        case .gpu: "GPU"
        case .energy: "Energy"
        case .thermals: "Thermals"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disks: "internaldrive"
        case .network: "network"
        case .gpu: "rectangle.3.group"
        case .energy: "bolt"
        case .thermals: "thermometer.medium"
        }
    }

    var metricKind: MetricKind {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .disks: .disk
        case .network: .network
        case .gpu: .gpu
        case .energy: .energy
        case .thermals: .thermals
        }
    }
}
