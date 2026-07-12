import SwiftUI

struct IslandView: View {
    @ObservedObject var model: IslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expandedContentTop: CGFloat {
        model.placement == .overlay ? IslandDesign.collapsedHeight : 0
    }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                StatusGlow(
                    status: model.status,
                    style: model.borderGlowStyle,
                    bottomRadius: surfaceShape.bottomRadius,
                    closesTop: model.placement == .floating,
                    reduceMotion: reduceMotion
                )
                .frame(width: IslandDesign.width, height: visualSurfaceHeight)

                ZStack(alignment: .top) {
                    InteractionCaptureView(
                        onClick: { model.onBlankClick?() },
                        onRightClick: { model.onContextMenu?($0) }
                    )

                    surfaceContent
                        .allowsHitTesting(false)

                    if model.isExpanded {
                        taskNavigationButtons
                            .transition(.opacity.combined(with: .offset(y: -3)))
                        quotaSwitchRows
                            .transition(.opacity)
                    }
                }
                .frame(width: IslandDesign.width, height: visualSurfaceHeight, alignment: .top)
                .background(IslandDesign.surface)
                .clipShape(surfaceShape)

                StatusCoreOutline(
                    status: model.status,
                    bottomRadius: surfaceShape.bottomRadius,
                    closesTop: model.placement == .floating
                )
                    .frame(width: IslandDesign.width, height: visualSurfaceHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: model.placement == .floating ? IslandDesign.glowOutset : 0)
            .animation(contentAnimation, value: model.isExpanded)
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var visualSurfaceHeight: CGFloat {
        if model.isExpanded {
            return model.placement == .overlay
                ? IslandDesign.overlayExpandedHeight
                : IslandDesign.floatingExpandedHeight
        }
        return model.placement == .overlay && model.usesWingLayout
            ? IslandDesign.overlayCollapsedHeight
            : IslandDesign.collapsedHeight
    }

    private var contentAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return model.isExpanded
            ? .timingCurve(0.70, 0, 1, 1, duration: 0.21)
            : .timingCurve(0.82, 0, 1, 1, duration: 0.15)
    }

    private var surfaceShape: IslandSurfaceShape {
        let topRadius: CGFloat = model.placement == .floating ? (model.isExpanded ? 18 : 16) : 0
        let bottomRadius: CGFloat = model.isExpanded ? 18 : 16
        return IslandSurfaceShape(topRadius: topRadius, bottomRadius: bottomRadius)
    }

    @ViewBuilder
    private var surfaceContent: some View {
        ZStack(alignment: .top) {
            if model.isExpanded {
                expandedRows
                    .padding(.top, expandedContentTop)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            } else {
                collapsedQuota
                    .frame(height: IslandDesign.collapsedHeight)
                    .transition(.opacity)
            }

        }
    }

    @ViewBuilder
    private var collapsedQuota: some View {
        let quota = model.activeQuotaPage == .fiveHour ? model.fiveHourQuota : model.weeklyQuota
        let kind = model.activeQuotaPage

        if model.usesWingLayout, model.physicalNotchWidth > 0 {
            let wingWidth = max((IslandDesign.width - model.physicalNotchWidth) / 2, 0)
            HStack(spacing: 0) {
                WingValue(
                    label: kind == .fiveHour ? "5h" : "周",
                    value: percentText(quota)
                )
                .frame(width: wingWidth)

                Color.clear.frame(width: model.physicalNotchWidth)

                WingValue(
                    label: wingResetLabel(kind: kind, quota: quota),
                    value: wingResetValue(quota)
                )
                .frame(width: wingWidth)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(model.activeQuotaPage == .fiveHour ? "5小时" : "本周")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandDesign.secondaryText)
                Text(percentText(quota))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(IslandDesign.primaryText)
                Spacer(minLength: 8)
                Text(collapsedResetText(quota))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(IslandDesign.tertiaryText)
            }
            .padding(.horizontal, 12)
        }
    }

    private var expandedRows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(model.selectedTaskCounter)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(IslandDesign.running)
                    .frame(width: 34, alignment: .leading)

                Text(model.selectedTask?.title ?? taskFallbackText)
                    .font(.system(size: 11.5, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color(red: 0.93, green: 0.95, blue: 0.97))

                Spacer(minLength: 58)
            }
            .padding(.leading, 12)
            .padding(.trailing, 7)
            .frame(height: IslandDesign.rowHeight)

            Divider().overlay(IslandDesign.separator)

            QuotaDetailRow(
                label: "5小时",
                bucketLabel: model.selectedQuotaBucketLabel,
                quota: model.selectedFiveHourQuota
            )

            Divider().overlay(IslandDesign.separator)

            QuotaDetailRow(
                label: "周额度",
                bucketLabel: model.selectedQuotaBucketLabel,
                quota: model.selectedWeeklyQuota
            )
        }
        .frame(height: IslandDesign.rowHeight * 3)
        .opacity(model.status == .disconnected ? 0.68 : 1)
    }

    private var taskNavigationButtons: some View {
        HStack(spacing: 0) {
            Spacer()
            TaskArrowButton(systemName: "chevron.left", label: "上一个正在运行的任务", disabled: model.tasks.count < 2) {
                model.selectPreviousTask()
            }
            TaskArrowButton(systemName: "chevron.right", label: "下一个正在运行的任务", disabled: model.tasks.count < 2) {
                model.selectNextTask()
            }
        }
        .padding(.trailing, 7)
        .padding(.top, expandedContentTop + 4)
        .frame(height: expandedContentTop + IslandDesign.rowHeight, alignment: .top)
    }

    private var quotaSwitchRows: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: expandedContentTop + IslandDesign.rowHeight)
                .allowsHitTesting(false)
            QuotaSwitchRowButton(
                currentBucketLabel: model.selectedQuotaBucketLabel,
                disabled: model.quotaBucketCount < 2,
                action: model.selectNextQuotaBucket
            )
            QuotaSwitchRowButton(
                currentBucketLabel: model.selectedQuotaBucketLabel,
                disabled: model.quotaBucketCount < 2,
                action: model.selectNextQuotaBucket
            )
        }
        .frame(width: IslandDesign.width, height: visualSurfaceHeight, alignment: .top)
    }

    private var taskFallbackText: String {
        switch model.status {
        case .disconnected: "任务状态未知"
        default: "当前无运行任务"
        }
    }

    private func percentText(_ quota: QuotaPresentation) -> String {
        quota.remainingPercent.map { "\($0)%" } ?? "--%"
    }

    private func collapsedResetText(_ quota: QuotaPresentation) -> String {
        guard let date = quota.resetsAt else {
            return model.quotaSourceMessage ?? "连接中"
        }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) + " 刷新"
    }

    private func wingResetLabel(kind: QuotaPagePresentation, quota: QuotaPresentation) -> String {
        guard let date = quota.resetsAt else { return "状态" }
        if kind == .fiveHour { return quota.isStale ? "旧值" : "刷新" }
        return Self.weekdayFormatter.string(from: date)
    }

    private func wingResetValue(_ quota: QuotaPresentation) -> String {
        guard let date = quota.resetsAt else { return "断连" }
        return Self.timeFormatter.string(from: date)
    }

    private var accessibilitySummary: String {
        let quota = model.activeQuotaPage == .fiveHour ? model.fiveHourQuota : model.weeklyQuota
        let kind = model.activeQuotaPage == .fiveHour ? "5小时额度" : "周额度"
        let remaining = quota.remainingPercent.map { "剩余\($0)%" } ?? "暂不可用"
        return "Codex \(model.status.localizedName)，\(kind)\(remaining)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

private struct WingValue: View {
    var label: String
    var value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color(red: 0.61, green: 0.65, blue: 0.70))
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(IslandDesign.primaryText)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuotaDetailRow: View {
    var label: String
    var bucketLabel: String?
    var quota: QuotaPresentation

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(IslandDesign.secondaryText)
                .frame(width: 44, alignment: .leading)
            Text(valueText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(IslandDesign.primaryText)
                .lineLimit(1)

            Spacer(minLength: 4)
            Text(detailResetText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(IslandDesign.tertiaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: IslandDesign.rowHeight)
    }

    private var valueText: String {
        let percent = quota.remainingPercent.map { "\($0)%" } ?? "--%"
        if let bucketLabel {
            return "\(bucketLabel) \(percent)"
        }
        return percent
    }

    private var detailResetText: String {
        guard let reset = quota.resetsAt else { return quota.isStale ? "旧值" : "连接中" }
        let value = Self.detailDateFormatter.string(from: reset)
        return quota.isStale ? "旧 · \(value)" : value
    }

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()
}

private struct QuotaSwitchRowButton: View {
    var currentBucketLabel: String?
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: IslandDesign.rowHeight)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("切换额度类型")
        .accessibilityHint(currentBucketLabel.map { "当前为\($0)额度" } ?? "当前为 Codex 额度")
    }
}

private struct TaskArrowButton: View {
    var systemName: String
    var label: String
    var disabled: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? IslandDesign.secondaryText.opacity(0.24) : (hovering ? Color.white : IslandDesign.secondaryText))
        .background(hovering && !disabled ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct IslandSurfaceShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        ).path(in: rect)
    }
}

private struct IslandStatusOutlineShape: Shape {
    var bottomRadius: CGFloat
    var closesTop: Bool

    func path(in rect: CGRect) -> Path {
        if closesTop {
            return RoundedRectangle(cornerRadius: bottomRadius, style: .continuous).path(in: rect)
        }

        let radius = min(bottomRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
        path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY - 0.5),
            control: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY - 0.5))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 0.5, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5)
        )
        path.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5))
        return path
    }
}

private struct StatusCoreOutline: View {
    var status: IslandVisualStatus
    var bottomRadius: CGFloat
    var closesTop: Bool

    private var color: Color {
        switch status {
        case .idle, .disconnected:
            IslandDesign.idle
        case .running, .waitingForUser, .error:
            IslandDesign.running
        }
    }

    var body: some View {
        IslandStatusOutlineShape(bottomRadius: bottomRadius, closesTop: closesTop)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
        .allowsHitTesting(false)
    }
}

private struct StatusGlow: View {
    var status: IslandVisualStatus
    var style: BorderGlowStyle
    var bottomRadius: CGFloat
    var closesTop: Bool
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !shouldAnimate)) { timeline in
            GeometryReader { _ in
                let seconds = timeline.date.timeIntervalSinceReferenceDate

                switch status {
                case .running:
                    runningGlow(seconds: seconds)

                case .waitingForUser:
                    glowLayers(color: status.color, intensity: 0.55)

                case .error:
                    let progress = reduceMotion ? 1 : seconds.truncatingRemainder(dividingBy: 2.4) / 2.4
                    let wave = 0.5 - 0.5 * cos(progress * 2 * .pi)
                    glowLayers(color: status.color, intensity: 0.45 + 0.37 * wave)

                case .idle, .disconnected:
                    Color.clear
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var shouldAnimate: Bool {
        guard !reduceMotion else { return false }
        return status == .error || status == .running
    }

    @ViewBuilder
    private func runningGlow(seconds: TimeInterval) -> some View {
        switch style {
        case .breathe:
            let progress = seconds.truncatingRemainder(dividingBy: 2.5) / 2.5
            let wave = reduceMotion ? 1 : 0.5 - 0.5 * cos(progress * 2 * .pi)
            // Approved preset: 100% peak, 28% minimum, 2.5s cycle.
            glowLayers(color: IslandDesign.running, intensity: 0.28 + 0.72 * wave)

        case .flow:
            flowGlow(progress: reduceMotion ? 0.5 : seconds.truncatingRemainder(dividingBy: 4) / 4)
        }
    }

    private func flowGlow(progress: Double) -> some View {
        ZStack {
            // Approved preset: 60% runner, 20% ambient, 4s loop,
            // 55% path length, #6D5DFC.
            glowLayers(color: IslandDesign.flow, intensity: 0.12)
            flowBandLayers(progress: progress, intensity: 0.60)
        }
    }

    private func flowBandLayers(progress: Double, intensity: Double) -> some View {
        let band = FlowBandShape(
            bottomRadius: bottomRadius,
            closesTop: closesTop,
            progress: progress,
            bandLength: 0.55
        )
        return ZStack {
            flowBandLayer(band, width: 3.5, blur: 0.7, opacity: intensity * 0.58)
            flowBandLayer(band, width: 5.0, blur: 1.4, opacity: intensity * 0.27)
            flowBandLayer(band, width: 6.5, blur: 2.4, opacity: intensity * 0.11)
            flowBandLayer(band, width: 7.0, blur: 3.5, opacity: intensity * 0.04)
        }
    }

    private func flowBandLayer(
        _ band: FlowBandShape,
        width: CGFloat,
        blur: CGFloat,
        opacity: Double
    ) -> some View {
        band
            .stroke(
                IslandDesign.flow,
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
            .blur(radius: blur)
            .opacity(opacity)
    }

    /// Four path-bound falloff layers reproduce the approved 3.5pt / 5.5pt
    /// visual profile without creating one rectangular Gaussian render texture.
    /// The black surface is above these layers, so the visible energy falls out.
    private func glowLayers(color: Color, intensity: Double) -> some View {
        ZStack {
            glowLayer(color: color, width: 3.5, blur: 0.7, opacity: intensity * 0.58)
            glowLayer(color: color, width: 5.0, blur: 1.4, opacity: intensity * 0.27)
            glowLayer(color: color, width: 6.5, blur: 2.4, opacity: intensity * 0.11)
            glowLayer(color: color, width: 7.0, blur: 3.5, opacity: intensity * 0.04)
        }
    }

    private func glowLayer(
        color: Color,
        width: CGFloat,
        blur: CGFloat,
        opacity: Double
    ) -> some View {
        IslandStatusOutlineShape(bottomRadius: bottomRadius, closesTop: closesTop)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
            .blur(radius: blur)
            .opacity(opacity)
    }
}

private struct FlowBandShape: Shape {
    var bottomRadius: CGFloat
    var closesTop: Bool
    var progress: Double
    var bandLength: Double

    func path(in rect: CGRect) -> Path {
        let base = IslandStatusOutlineShape(
            bottomRadius: bottomRadius,
            closesTop: closesTop
        ).path(in: rect)
        let start = progress.truncatingRemainder(dividingBy: 1)
        let end = start + bandLength

        if end <= 1 {
            return base.trimmedPath(from: start, to: end)
        }

        var path = base.trimmedPath(from: start, to: 1)
        path.addPath(base.trimmedPath(from: 0, to: end - 1))
        return path
    }
}
