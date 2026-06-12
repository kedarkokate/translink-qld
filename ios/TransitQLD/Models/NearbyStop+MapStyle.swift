import SwiftUI

extension NearbyStop {
    /// SF Symbol used for the map pin / picker row icon, based on what modes
    /// of transport serve this stop. Priority: ferry > rail > bus.
    var modeSymbolName: String {
        if isFerry { return "ferry.fill" }
        if isRail  { return "train.side.front.car" }
        return "bus.fill"
    }

    /// Tint colour matching `modeSymbolName`. The four map-pin states —
    /// bus red, rail indigo, ferry cyan, focused-stop green — sit at well-
    /// separated points on the colour wheel and stay distinguishable under
    /// the common red-green colour-blindness profiles. Indigo also has
    /// enough luminance darkness to read as a filled pin on Apple Maps'
    /// light cream background AND on the dark-mode map (yellow looked
    /// vibrant on dark but washed out on light), while keeping the white
    /// SF Symbol icon legible.
    var modeTint: Color {
        if isFerry { return Self.ferryTint }
        if isRail  { return Self.railTint }
        return .red
    }

    /// Richer than SwiftUI's `.cyan` so the white SF Symbol / pill text on
    /// top stays AA-contrast legible (Apple's `.cyan` is too bright in dark
    /// mode for white text to read). Used wherever a ferry mode is rendered.
    static let ferryTint = Color(red: 0, green: 168/255, blue: 200/255)

    /// Web/CSS "Indigo" (#4B0082) — deep saturated purple. High contrast
    /// against white SF Symbol (~12:1) and well clear of bus red and
    /// ferry teal-cyan. Watch for legibility on the dark-mode map where
    /// the charcoal background can swallow very dark purples.
    static let railTint = Color(red: 75/255, green: 0, blue: 130/255)
}
