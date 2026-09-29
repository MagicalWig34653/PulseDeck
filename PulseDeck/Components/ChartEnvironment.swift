import SwiftUI

extension EnvironmentValues {
    /// Seconds over which a full-size chart scrolls from one sample to the next, or `nil` for no
    /// smooth scrolling (the setting is off, the window is in the background, Reduce Motion is
    /// on, or updates are paused).
    @Entry var chartScrollInterval: Double? = nil
}
