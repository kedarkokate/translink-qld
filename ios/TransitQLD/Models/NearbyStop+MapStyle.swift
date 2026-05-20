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
    /// bus red, rail indigo, ferry blue, focused-stop green — sit at well-
    /// separated points on the colour wheel and stay distinguishable under
    /// the common red-green colour-blindness profiles. Indigo also has
    /// enough luminance darkness to read as a filled pin on Apple Maps'
    /// light cream background AND on the dark-mode map (yellow looked
    /// vibrant on dark but washed out on light), while keeping the white
    /// SF Symbol icon legible.
    var modeTint: Color {
        if isFerry { return .blue }
        if isRail  { return .indigo }
        return .red
    }
}
