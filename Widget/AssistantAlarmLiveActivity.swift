import SwiftUI
import WidgetKit

#if canImport(AlarmKit)
import AlarmKit

/// Lock Screen and Dynamic Island presentation for every alarm this app schedules.
///
/// The Stop and Snooze buttons themselves are drawn by the system from the `AlarmPresentation`
/// supplied at schedule time — this only supplies the surrounding surface and the countdown.
struct AssistantAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<AssistantAlarmMetadata>.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbol(for: context.attributes.metadata))
                        .font(.title2)
                        .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: context.attributes.metadata))
                            .font(.headline)
                            .lineLimit(1)
                        if let project = projectLabel(for: context.attributes.metadata) {
                            Text(project)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    countdown(context)
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: symbol(for: context.attributes.metadata))
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                countdown(context)
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: symbol(for: context.attributes.metadata))
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
    }

    // MARK: - Lock screen

    private func lockScreen(_ context: ActivityViewContext<AlarmAttributes<AssistantAlarmMetadata>>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol(for: context.attributes.metadata))
                .font(.system(size: 30))
                .foregroundStyle(context.attributes.tintColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: context.attributes.metadata))
                    .font(.headline)
                    .lineLimit(2)
                if let project = projectLabel(for: context.attributes.metadata) {
                    Text(project)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            countdown(context)
                .font(.system(.title3, design: .rounded).monospacedDigit())
        }
        .padding(16)
    }

    /// The one place that reads `AlarmPresentationState`. If Apple renames a member of the
    /// countdown payload between SDK builds, this is the only view that has to change.
    @ViewBuilder
    private func countdown(_ context: ActivityViewContext<AlarmAttributes<AssistantAlarmMetadata>>) -> some View {
        switch context.state.mode {
        case .countdown(let info):
            Text(timerInterval: Date.now...info.fireDate, countsDown: true)
                .monospacedDigit()
        case .paused:
            Image(systemName: "pause.circle")
        case .alert:
            Image(systemName: "bell.badge.fill")
                .symbolEffect(.pulse)
        @unknown default:
            EmptyView()
        }
    }

    // MARK: - Metadata

    private func title(for metadata: AssistantAlarmMetadata?) -> String {
        guard let metadata, !metadata.title.isEmpty else { return "Alarm" }
        return metadata.title
    }

    private func projectLabel(for metadata: AssistantAlarmMetadata?) -> String? {
        guard let metadata, metadata.projectName != "Life", !metadata.projectName.isEmpty else { return nil }
        return metadata.projectName
    }

    private func symbol(for metadata: AssistantAlarmMetadata?) -> String {
        (metadata?.isDailyReview ?? false) ? "checklist" : "alarm.waves.left.and.right.fill"
    }
}

#else

/// Keeps the widget target compiling on an SDK without AlarmKit. The app cannot schedule alarms
/// there either, so an empty bundle is the honest result rather than a fake alarm surface.
struct AssistantAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "assistant.placeholder", provider: PlaceholderProvider()) { _ in
            Text("Alarms require iOS 26.")
        }
    }
}

struct PlaceholderEntry: TimelineEntry { let date: Date }

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

#endif
