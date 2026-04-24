import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var index = AppIndex.shared
    @State private var query: String = ""
    @State private var selection: Int = 0
    @State private var recents: [String] = Recents.load()
    @FocusState private var searchFocused: Bool

    private var results: [AppEntry] {
        SearchEngine.search(query: query, in: index.apps, recents: recents)
    }

    private var visible: [AppEntry] {
        Array(results.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.2)
            resultsList
        }
        .background(
            VisualEffectView(material: .hudWindow, blending: .behindWindow)
                .ignoresSafeArea()
        )
        .ignoresSafeArea()
        .onAppear {
            forceFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShouldFocus)) { _ in
            query = ""
            selection = 0
            forceFocus()
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search apps…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)
                .onSubmit { open() }
                .onKeyPress(.upArrow) {
                    move(-1); return .handled
                }
                .onKeyPress(.downArrow) {
                    move(+1); return .handled
                }
                .onKeyPress(.escape) {
                    hide(); return .handled
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var resultsList: some View {
        if visible.isEmpty && !query.isEmpty {
            emptyState
        } else if visible.isEmpty {
            // Empty query + no apps indexed yet (first run). Show nothing.
            Color.clear.frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, app in
                            ResultRow(
                                app: app,
                                icon: index.icon(for: app),
                                selected: idx == selection
                            )
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { launch(app) }
                            .onTapGesture { selection = idx }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.08)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Results")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No apps match \"\(query)\"")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - actions

    private func move(_ dir: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = (selection + dir + count) % count
    }

    private func open() {
        guard selection < visible.count else { return }
        launch(visible[selection])
    }

    private func launch(_ app: AppEntry) {
        let ok = AppIndex.shared.open(app)
        if ok {
            Recents.record(app.path)
            recents = Recents.load()
            hide()
        } else {
            // App was deleted since index. Drop from recents, keep window open.
            Recents.forget(app.path)
            recents = Recents.load()
            selection = 0
        }
    }

    private func hide() {
        query = ""
        selection = 0
        // Use classic macOS "hide application" behavior — window goes away
        // cleanly without animation glitches, dock click brings it back via
        // applicationShouldHandleReopen.
        NSApp.hide(nil)
    }

    /// Belt-and-suspenders focus: toggle @FocusState (forces SwiftUI re-eval)
    /// AND walk the NSView tree to find the underlying NSTextField and
    /// make it first responder. Needed because on window re-show, SwiftUI's
    /// focus binding alone doesn't always stick.
    private func forceFocus() {
        searchFocused = false
        DispatchQueue.main.async {
            searchFocused = true
            if let w = NSApp.windows.first(where: { $0.isVisible }),
               let content = w.contentView,
               let tf = findTextField(in: content) {
                w.makeFirstResponder(tf)
            }
        }
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField, tf.isEditable { return tf }
        for sub in view.subviews {
            if let found = findTextField(in: sub) { return found }
        }
        return nil
    }
}

struct ResultRow: View {
    let app: AppEntry
    let icon: NSImage
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            Text(app.name)
                .font(.system(size: 15))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary)
            Spacer()
            Text(shortPath)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.9) : Color.clear)
        )
    }

    private var shortPath: String {
        let p = app.path
        if p.hasPrefix("/Applications/") { return "Applications" }
        if p.hasPrefix("/System/Applications/Utilities/") { return "Utilities" }
        if p.hasPrefix("/System/Applications/") { return "System" }
        if p.contains("/Applications/") { return "User" }
        return (p as NSString).deletingLastPathComponent
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
