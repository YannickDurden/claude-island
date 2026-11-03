import SwiftUI

struct IslandView: View {
    let store: SessionStore
    let layout: IslandLayout
    /// Reports the island shape's frame so the panel can track the mouse against it.
    let onFrameChange: (CGRect) -> Void

    private var notch: CGSize { layout.notch }
    private var expanded: Bool {
        layout.isHovering || !store.permissions.isEmpty || store.hasQuestions || store.justFinished != nil
    }

    var body: some View {
        // A single container: modifiers on a Group would be duplicated onto each branch.
        VStack(spacing: 0) {
            if expanded { panel.transition(.opacity) } else { pill.transition(.opacity) }
        }
        .foregroundStyle(.white)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 22 : 12,
                                                         bottomTrailingRadius: expanded ? 22 : 12))
        // Without a real notch, an empty island would just be a black bar over the menu bar.
        .opacity(store.alerting == nil && !layout.hasNotch && !expanded ? 0 : 1)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: onFrameChange)
        .padding(.trailing, notchCentring)
        .animation(.spring(duration: 0.3), value: expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Collapsed: exactly the notch, with wings (name, count) only while a session waits on the user.
    private var pill: some View {
        HStack(spacing: 0) {
            if let session = store.alerting {
                HStack(spacing: 6) {
                    StatusDot(status: session.status)
                    Text(session.name).font(.caption.bold()).lineLimit(1)
                }
                .frame(width: Self.leftWing, alignment: .leading)
                Color.clear.frame(width: notch.width)
                Text("\(store.sessions.count)").font(.caption.bold())
                    .frame(width: Self.rightWing, alignment: .trailing)
            } else {
                Color.clear.frame(width: notch.width)
            }
        }
        .padding(.horizontal, store.alerting == nil ? 0 : 10)
        .frame(height: notch.height)
    }

    /// Kept narrow so the pill does not cover menu bar items next to the notch;
    /// the right side, crowded with status icons, only holds the count.
    private static let leftWing: CGFloat = 70
    private static let rightWing: CGFloat = 24
    /// Trailing padding outside the shape that keeps the notch centred despite unequal wings.
    private var notchCentring: CGFloat {
        expanded || store.alerting == nil ? 0 : Self.leftWing - Self.rightWing
    }

    /// Takes the user to the session, drops its question card and folds the island away.
    private func open(_ sessionId: String) {
        store.dismissQuestion(of: sessionId)
        layout.hoverSuppressed = true
        layout.isHovering = false
        store.sessions.first { $0.id == sessionId }?.focusTerminal()
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.permissions) { permission in
                PermissionCard(permission: permission, store: store) {
                    // No decision: Claude's own prompt, already shown in the session, takes over.
                    store.decide(permission, .terminal)
                    open(permission.sessionId)
                }
            }
            ForEach(store.sessions.filter { $0.question != nil }) { session in
                QuestionCard(session: session) { open(session.id) }
            }
            if let id = store.justFinished {
                FinishedCard(name: store.name(of: id)) { open(id) }
            }
            ForEach(store.sessions) { session in
                SessionRow(session: session) { open(session.id) }
            }
            if store.sessions.isEmpty {
                Text("Aucune session Claude").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, notch.height + 6)
        .padding(.bottom, 12)
        .frame(width: 360, alignment: .leading)
    }
}

private struct PermissionCard: View {
    let permission: SessionStore.Permission
    let store: SessionStore
    /// Answer in the session instead.
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(store.name(of: permission.sessionId)) veut utiliser \(permission.tool)", systemImage: "lock.shield")
                .font(.callout.bold())
            if !permission.detail.isEmpty {
                Text(permission.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack {
                Button("Autoriser") { store.decide(permission, .allow) }.tint(.green)
                Button("Refuser") { store.decide(permission, .deny) }.tint(.red)
                Button("Ouvrir", action: onOpen).tint(.gray)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

/// Shown for a few seconds when a session finishes its turn.
private struct FinishedCard: View {
    let name: String
    let onOpen: () -> Void

    var body: some View {
        Label("\(name) a terminé", systemImage: "checkmark.circle.fill")
            .font(.callout.bold())
            .symbolRenderingMode(.multicolor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
    }
}

/// Claude's question is answered in the session itself: a click takes the user there.
private struct QuestionCard: View {
    let session: SessionStore.Session
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(session.name) te pose une question", systemImage: "questionmark.bubble")
                .font(.callout.bold())
            Text(session.question ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Text("Cliquer pour répondre").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
    }
}

private struct SessionRow: View {
    let session: SessionStore.Session
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StatusDot(status: session.status)
                Text(session.name).font(.callout.bold())
                Text(session.activity).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
            ForEach(session.subagents) { agent in
                HStack(spacing: 8) {
                    Label(agent.type, systemImage: agent.running ? "arrow.triangle.branch" : "checkmark")
                        .foregroundStyle(agent.running ? .primary : .secondary)
                    if agent.running {
                        Text(agent.activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .padding(.leading, 16)
            }
        }
    }
}

private struct StatusDot: View {
    let status: SessionStore.Status

    var body: some View {
        if status == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.blue)
                .frame(width: 8, height: 8)
        } else {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private var color: Color {
        switch status {
        case .working: .green
        case .attention: .orange
        case .idle, .done: .gray
        }
    }
}
