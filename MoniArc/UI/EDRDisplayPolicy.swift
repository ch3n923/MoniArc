import CoreGraphics

struct EDRDisplayPolicy: Equatable, Sendable {
    var requestsHDR: Bool
    var maximumPotentialHeadroom: CGFloat
    var maximumCurrentHeadroom: CGFloat

    var shouldRequestEDR: Bool {
        requestsHDR && maximumPotentialHeadroom > 1
    }

    var availableHeadroom: Float {
        guard shouldRequestEDR else { return 1 }
        // macOS reports a current value of 1.0 until an onscreen layer actually
        // submits EDR pixels. Seed the first frame from the display's potential
        // headroom, then follow the current value once the compositor publishes it.
        let current = Float(maximumCurrentHeadroom)
        let potential = Float(maximumPotentialHeadroom)
        let activeHeadroom = current > 1 ? current : potential
        return max(1, activeHeadroom * 0.95)
    }

    func clampedHDRBrightness(_ requestedBrightness: Float) -> Float {
        min(max(1, requestedBrightness), availableHeadroom)
    }
}
