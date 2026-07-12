import SwiftUI

enum BorderGlowStyle: String, CaseIterable, Sendable {
    case breathe
    case flow

    var localizedName: String {
        switch self {
        case .breathe: "呼吸光效"
        case .flow: "流动光效"
        }
    }
}

enum IslandDesign {
    static let surface = Color.black
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.67, green: 0.70, blue: 0.75)
    static let tertiaryText = Color(red: 0.52, green: 0.56, blue: 0.61)
    static let separator = Color.white.opacity(0.075)

    static let running = Color("Running")
    static let waiting = Color("Waiting")
    static let error = Color("Error")
    static let idle = Color("Idle")
    static let offline = Color("Offline")
    static let flow = Color(red: 0x6D / 255, green: 0x5D / 255, blue: 0xFC / 255)

    static let width: CGFloat = 304
    static let collapsedHeight: CGFloat = 32
    static let overlayCollapsedHeight: CGFloat = 34
    static let overlayExpandedHeight: CGFloat = 140
    static let floatingExpandedHeight: CGFloat = 108
    /// Enough transparent room for SwiftUI's Gaussian blur to decay before
    /// the NSPanel edge, preventing a visible rectangular clipping boundary.
    /// Keep more than four blur radii between the halo and NSPanel bounds.
    /// This prevents Core Animation's offscreen blur texture from exposing a
    /// rectangular edge at peak opacity or during panel resizing.
    static let glowOutset: CGFloat = 28
    static let rowHeight: CGFloat = 36
    static let floatingRadius: CGFloat = 16
    static let expandedRadius: CGFloat = 18
}

extension IslandVisualStatus {
    var color: Color {
        switch self {
        case .running: IslandDesign.running
        case .waitingForUser: IslandDesign.waiting
        case .error: IslandDesign.error
        case .idle: IslandDesign.idle
        case .disconnected: IslandDesign.offline
        }
    }

    var localizedName: String {
        switch self {
        case .running: "运行中"
        case .waitingForUser: "等待用户"
        case .error: "发生错误"
        case .idle: "空闲"
        case .disconnected: "任务源断开"
        }
    }

    static var displayCases: [IslandVisualStatus] {
        [.running, .waitingForUser, .error, .idle, .disconnected]
    }
}
