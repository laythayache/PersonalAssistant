import SwiftUI

/// Text that lays itself out in the direction of its own content.
///
/// A chat here mixes English, Arabic and Arabizi in the same thread, sometimes in the same message.
/// SwiftUI will not flip a single `Text` for you, so an Arabic bubble left at the app's LTR
/// direction gets its punctuation dragged to the wrong end and reads as broken Arabic.
struct DirectionalText: View {
    let text: String
    var font: Font = .body

    private var isRTL: Bool {
        Normalizer.detectScript(text) == .arabic
    }

    var body: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
    }
}

/// A compact pill. Used for the AM/PM correction and the quick actions above the keyboard.
struct QuickChip: View {
    let title: String
    var systemImage: String?
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(isProminent ? Color.accentColor : Color(.secondarySystemBackground),
                    in: Capsule())
        .foregroundStyle(isProminent ? Color.white : Color.primary)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StatusBanner: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(tint)
    }
}

/// Hour + minute only. Used everywhere a time is chosen, so the interaction is identical each time.
struct CompactDateTimePicker: View {
    @Binding var date: Date
    var label: String = "New time"

    var body: some View {
        DatePicker(label, selection: $date, displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.compact)
            .labelsHidden()
    }
}

extension OccurrenceStatus {
    var tint: Color {
        switch self {
        case .scheduled: return .accentColor
        case .pendingReview: return .orange
        case .completed: return .green
        case .missed: return .red
        case .postponed: return .purple
        case .cancelled: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .scheduled: return "alarm"
        case .pendingReview: return "questionmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .postponed: return "arrow.uturn.right.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }
}
