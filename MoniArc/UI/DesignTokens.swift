import SwiftUI

extension GlowMotionOverride {
    var localizedName: String {
        switch self {
        case .automatic: "自动"
        case .breathe: "呼吸"
        case .flow: "流动"
        }
    }
}

extension HDROverride {
    var localizedName: String {
        switch self {
        case .automatic: "自动"
        case .on: "开启"
        case .off: "关闭"
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

    static let inactiveGlow = Color(red: 0x85 / 255, green: 0x8D / 255, blue: 0x99 / 255)
    static let solGlow = Color(red: 0xFF / 255, green: 0xC8 / 255, blue: 0x3D / 255)
    static let terraGlow = Color(red: 0x55 / 255, green: 0xD6 / 255, blue: 0xFF / 255)
    static let lunaGlow = Color(red: 0xF4 / 255, green: 0xFA / 255, blue: 0xFF / 255)
    static let otherGlow = Color(red: 0x28 / 255, green: 0xC8 / 255, blue: 0x40 / 255)

    static let width: CGFloat = 304
    static let collapsedHeight: CGFloat = 32
    static let overlayCollapsedHeight: CGFloat = 34
    static let overlayExpandedHeight: CGFloat = 140
    static let floatingExpandedHeight: CGFloat = 108
    /// Transparent room for the widest Sol corona to decay before the panel
    /// edge. The Metal renderer's largest flare needs roughly three Gaussian
    /// radii here; otherwise its halo becomes a visibly clipped rectangle.
    static let glowOutset: CGFloat = 104
    static let rowHeight: CGFloat = 36
    static let floatingRadius: CGFloat = 16
    static let expandedRadius: CGFloat = 18
}

extension TaskLightingTheme {
    var glowColor: Color {
        switch self {
        case .sol: IslandDesign.solGlow
        case .terra: IslandDesign.terraGlow
        case .luna: IslandDesign.lunaGlow
        case .other: IslandDesign.otherGlow
        }
    }
}

extension ResolvedGlowAppearance {
    var glowColor: Color {
        isBusy ? theme.glowColor : IslandDesign.inactiveGlow
    }
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
