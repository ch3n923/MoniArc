import AppKit
import Combine
import Foundation

struct QuotaPresentation: Equatable, Sendable {
    var remainingPercent: Int?
    var resetsAt: Date?
    var isStale: Bool

    static let unavailable = QuotaPresentation(remainingPercent: nil, resetsAt: nil, isStale: true)

    var isAvailable: Bool {
        remainingPercent != nil
    }
}

struct IslandTaskPresentation: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
}

struct AdditionalQuotaPresentation: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var fiveHour: QuotaPresentation
    var weekly: QuotaPresentation

    subscript(kind: QuotaPagePresentation) -> QuotaPresentation {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        }
    }
}

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var placement: PanelPlacement = .floating
    @Published var isExpanded = false
    @Published var usesWingLayout = false
    @Published var physicalNotchWidth: CGFloat = 0
    @Published var activeQuotaPage: QuotaPagePresentation = .fiveHour
    @Published var fiveHourQuota: QuotaPresentation = .unavailable
    @Published var weeklyQuota: QuotaPresentation = .unavailable
    @Published var additionalQuotas: [AdditionalQuotaPresentation] = []
    @Published var selectedQuotaBucketIndex = 0
    @Published var tasks: [IslandTaskPresentation] = []
    @Published var selectedTaskIndex = 0
    @Published var status: IslandVisualStatus = .disconnected
    @Published var borderGlowStyle: BorderGlowStyle = .breathe
    @Published var quotaSourceMessage: String?

    var onPreviousTask: (() -> Void)?
    var onNextTask: (() -> Void)?
    var onContextMenu: ((CGPoint) -> Void)?

    var selectedTask: IslandTaskPresentation? {
        guard tasks.indices.contains(selectedTaskIndex) else { return nil }
        return tasks[selectedTaskIndex]
    }

    var selectedTaskCounter: String {
        guard !tasks.isEmpty else { return "—" }
        return "\(selectedTaskIndex + 1)/\(tasks.count)"
    }

    var quotaBucketCount: Int {
        1 + additionalQuotas.count
    }

    var selectedQuotaBucketLabel: String? {
        let index = selectedQuotaBucketIndex - 1
        guard selectedQuotaBucketIndex > 0, additionalQuotas.indices.contains(index) else { return nil }
        return additionalQuotas[index].label
    }

    var selectedFiveHourQuota: QuotaPresentation {
        let index = selectedQuotaBucketIndex - 1
        guard selectedQuotaBucketIndex > 0, additionalQuotas.indices.contains(index) else { return fiveHourQuota }
        return additionalQuotas[index].fiveHour
    }

    var selectedWeeklyQuota: QuotaPresentation {
        let index = selectedQuotaBucketIndex - 1
        guard selectedQuotaBucketIndex > 0, additionalQuotas.indices.contains(index) else { return weeklyQuota }
        return additionalQuotas[index].weekly
    }

    func normalizeTaskSelection() {
        if tasks.isEmpty {
            selectedTaskIndex = 0
        } else {
            selectedTaskIndex = min(max(selectedTaskIndex, 0), tasks.count - 1)
        }
    }

    func normalizeQuotaBucketSelection() {
        selectedQuotaBucketIndex = min(max(selectedQuotaBucketIndex, 0), quotaBucketCount - 1)
    }

    /// Keeps the collapsed island on a window that the Codex server actually returned.
    /// Some accounts currently expose only the weekly window, which is not a disconnect.
    func normalizeActiveQuotaPage() {
        switch activeQuotaPage {
        case .fiveHour where !fiveHourQuota.isAvailable && weeklyQuota.isAvailable:
            activeQuotaPage = .weekly
        case .weekly where !weeklyQuota.isAvailable && fiveHourQuota.isAvailable:
            activeQuotaPage = .fiveHour
        default:
            break
        }
    }

    func selectPreviousQuotaBucket() {
        guard quotaBucketCount > 1 else { return }
        selectedQuotaBucketIndex = (selectedQuotaBucketIndex - 1 + quotaBucketCount) % quotaBucketCount
    }

    func selectNextQuotaBucket() {
        guard quotaBucketCount > 1 else { return }
        selectedQuotaBucketIndex = (selectedQuotaBucketIndex + 1) % quotaBucketCount
    }

    func selectPreviousTask() {
        guard tasks.count > 1 else { return }
        selectedTaskIndex = (selectedTaskIndex - 1 + tasks.count) % tasks.count
        onPreviousTask?()
    }

    func selectNextTask() {
        guard tasks.count > 1 else { return }
        selectedTaskIndex = (selectedTaskIndex + 1) % tasks.count
        onNextTask?()
    }
}

enum QuotaPagePresentation: String, Sendable {
    case fiveHour
    case weekly
}
