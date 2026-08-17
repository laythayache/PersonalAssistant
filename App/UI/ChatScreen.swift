import SwiftUI
import SwiftData

/// The screen the app opens on. Everything else is one tap away from here.
struct ChatScreen: View {
    let engine: AssistantEngine
    @Bindable var router: AppRouter

    @Query(sort: \Message.createdAt, order: .forward) private var messages: [Message]

    @State private var draft = ""
    @State private var showUpcoming = false
    @State private var showProjects = false
    @State private var showDiagnostics = false
    @State private var reviewSheet: ReviewSheet?
    @FocusState private var inputFocused: Bool

    struct ReviewSheet: Identifiable {
        let id: String
        var dayKey: String { id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banners
                nextUpStrip
                transcript
                composer
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .background(Color(.systemBackground))
        }
        .sheet(isPresented: $showUpcoming) {
            UpcomingScreen(engine: engine)
        }
        .sheet(isPresented: $showProjects) {
            ProjectsScreen(engine: engine)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsScreen(engine: engine)
        }
        .sheet(item: $reviewSheet) { sheet in
            DailyReviewScreen(engine: engine, dayKey: sheet.dayKey)
        }
        .onChange(of: router.route) { _, route in
            if case .dailyReview(let dayKey) = route {
                reviewSheet = ReviewSheet(id: dayKey)
                router.route = .chat
            }
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if PersistenceController.isEphemeral {
                StatusBanner(text: "Storage failed to open. Nothing typed now will survive a restart.",
                             tint: .red)
            }
            if engine.authorizationDenied {
                StatusBanner(text: "Alarm permission is off — alarms will not ring. Settings › Assistant.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, engine.authorizationDenied || PersistenceController.isEphemeral ? 8 : 0)
    }

    // MARK: - What's next, always visible, one line

    @ViewBuilder
    private var nextUpStrip: some View {
        let next = engine.upcoming(limit: 1).first
        let pendingDays = engine.daysNeedingReview()

        HStack(spacing: 8) {
            Button {
                showUpcoming = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "alarm")
                        .font(.footnote)
                    if let next {
                        Text(Phrasing.relative(next.scheduledAt))
                            .font(.footnote.weight(.semibold))
                        Text(next.title)
                            .font(.footnote)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Nothing scheduled")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if let day = pendingDays.first {
                Button {
                    reviewSheet = ReviewSheet(id: day)
                } label: {
                    Label("\(pendingDays.count)", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty { emptyState }
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if engine.isWorking {
                        ProgressView()
                            .padding(.leading, 16)
                            .id("working")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type what you want.")
                .font(.headline)
            Text("“Remind me tomorrow at 4 to call Riad”\n“Every Monday at 9 send the report”\n“zakkerne bokra 4 etsel b Riad”\n“ذكرني بكرا الساعة ٤ اتصل برياض”")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let pending = engine.pending {
                PendingCard(engine: engine, pending: pending)
                    .padding(.horizontal, 12)
            }

            if let chip = engine.meridiemChip {
                HStack {
                    QuickChip(title: "Actually \(Phrasing.time(chip.alternative))",
                              systemImage: "arrow.left.arrow.right") {
                        Task { await engine.flipMeridiem() }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isWorking)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await engine.send(text) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                Task { await engine.send("What's next?") }
            } label: {
                Label("What's next", systemImage: "arrow.right.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Upcoming alarms", systemImage: "alarm") { showUpcoming = true }
                Button("Today's review", systemImage: "checklist") {
                    reviewSheet = ReviewSheet(id: DayKey.today())
                }
                Button("Projects", systemImage: "folder") { showProjects = true }
                Divider()
                Button("Diagnostics", systemImage: "stethoscope") { showDiagnostics = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
