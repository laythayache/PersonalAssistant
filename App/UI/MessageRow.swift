import SwiftUI
import UIKit

struct MessageRow: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            DirectionalText(text: message.text, font: .body)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isUser ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !isUser { Spacer(minLength: 40) }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
            if !message.commandJSON.isEmpty {
                Button("Copy interpretation", systemImage: "curlybraces") {
                    UIPasteboard.general.string = message.commandJSON
                }
            }
        }
    }
}
