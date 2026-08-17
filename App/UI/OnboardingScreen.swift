import SwiftUI

/// Two things only: explain the one permission, and ask for the End-of-Day Review time.
///
/// Requirement 11 is explicit that the review time must be asked for and never invented, so the
/// stored value stays nil until a button is actually pressed — skipping leaves it nil and no
/// review alarm is ever created.
struct OnboardingScreen: View {
    let engine: AssistantEngine

    @State private var reviewTime = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: .now) ?? .now
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Everything stays on this phone.")
                            .font(.title3.weight(.semibold))
                        Text("No account, no server, no network. Your alarms, notes and chat history are stored locally and are not sent anywhere.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    SectionCard(title: "THE ONE PERMISSION") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Alarms", systemImage: "alarm.waves.left.and.right")
                                .font(.subheadline.weight(.semibold))
                            Text("iOS needs your permission for this app to schedule real alarms. Without it a reminder can only be a quiet notification that you will miss.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Nothing else is requested — no contacts, calendar, location, microphone, photos or health data.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SectionCard(title: "END OF DAY REVIEW") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("On any day where you actually set an alarm, one evening alarm asks you to mark what happened. Days with no alarms are skipped entirely.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("What time suits you?")
                                .font(.subheadline.weight(.medium))
                            DatePicker("Review time", selection: $reviewTime, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                                .frame(maxHeight: 130)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        finish(withReviewTime: true)
                    } label: {
                        Text("Use \(reviewTime.formatted(.dateTime.hour().minute())) and continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Skip — no daily review") {
                        finish(withReviewTime: false)
                    }
                    .font(.footnote)
                }
                .padding(16)
                .background(.bar)
                .disabled(isFinishing)
            }
        }
    }

    private func finish(withReviewTime: Bool) {
        isFinishing = true
        let settings = engine.store.settings()
        if withReviewTime {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: reviewTime)
            settings.endOfDayHour = comps.hour
            settings.endOfDayMinute = comps.minute
        } else {
            settings.endOfDayHour = nil
            settings.endOfDayMinute = nil
        }
        settings.hasCompletedOnboarding = true
        settings.modifiedAt = .now
        engine.store.save("finish onboarding")

        Task {
            await engine.bootstrap()
            isFinishing = false
        }
    }
}
