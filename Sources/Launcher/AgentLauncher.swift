import AppKit
import Foundation

enum AgentTool: String, CaseIterable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var commandName: String { rawValue }

    var aliases: [String] {
        switch self {
        case .codex:
            return ["codex", "agent", "coding agent", "code agent"]
        case .claude:
            return ["claude", "claude code"]
        }
    }
}

struct AgentSession: Identifiable, Hashable {
    let tool: AgentTool
    let projectName: String
    let workdir: String
    let modifiedAt: Date

    var id: String { "agent:\(tool.rawValue):\(workdir)" }
    var name: String { "\(tool.displayName): \(projectName)" }

    var shortPath: String {
        let home = NSHomeDirectory()
        if workdir == home { return "~" }
        if workdir.hasPrefix(home + "/") {
            return "~/" + String(workdir.dropFirst(home.count + 1))
        }
        return workdir
    }

    var appEntry: AppEntry {
        let normalizedProjectName = Self.searchText(projectName)
        let normalizedShortPath = Self.searchText(shortPath)
        let pathParts = shortPath
            .replacingOccurrences(of: "~", with: "home")
            .split(separator: "/")
            .map(String.init)
        let aliases = [
            name,
            projectName,
            normalizedProjectName,
            shortPath,
            normalizedShortPath,
            workdir,
        ] + tool.aliases
            + tool.aliases.map { "\($0) \(projectName)" }
            + tool.aliases.map { "\($0) \(normalizedProjectName)" }
            + pathParts
        return AppEntry(path: id, name: name, aliases: aliases)
    }

    var commandLine: String {
        "cd \(Self.shellQuote(workdir)) && \(tool.commandName)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func searchText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "~", with: "home")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

final class AgentCatalog: ObservableObject {
    static let shared = AgentCatalog()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var indexed = SearchIndex()

    private var byID: [String: AgentSession] = [:]
    private let queue = DispatchQueue(label: "launcher.agents", qos: .utility)
    private var didLoad = false

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        refresh()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let sessions = self.discoverSessions()
            let indexed = SearchIndex(sessions.map(\.appEntry))
            let byID = Dictionary(uniqueKeysWithValues: zip(sessions.map(\.id), sessions))
            DispatchQueue.main.async {
                self.sessions = sessions
                self.indexed = indexed
                self.byID = byID
            }
        }
    }

    func scanSync() -> [AgentSession] {
        discoverSessions()
    }

    func search(query: String) -> [AgentSession] {
        guard Self.hasAgentIntent(query) else { return [] }
        let results = SearchEngine.search(query: query, in: indexed, recents: AgentRecents.load())
        return results.compactMap { byID[$0.path] }
    }

    @discardableResult
    func open(_ session: AgentSession) -> Bool {
        guard FileManager.default.fileExists(atPath: session.workdir) else {
            refresh()
            return false
        }
        return TerminalCommandLauncher.shared.run(command: session.commandLine, workdir: session.workdir)
    }

    static func hasAgentIntent(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let variants = KeyboardLayout.variants(trimmed.lowercased())
        let needles = ["agent", "codex", "claude", "coding"]
        return variants.contains { variant in
            needles.contains { needle in
                variant == needle || variant.hasPrefix(needle + " ") || variant.contains(" " + needle)
            }
        }
    }

    private func discoverSessions() -> [AgentSession] {
        let tools = AgentTool.allCases.filter { Self.commandIsAvailable($0.commandName) }
        guard !tools.isEmpty else { return [] }

        let projects = discoverProjects()
        let sessions = projects.flatMap { project in
            tools.map {
                AgentSession(
                    tool: $0,
                    projectName: project.name,
                    workdir: project.path,
                    modifiedAt: project.modifiedAt
                )
            }
        }
        return sessions.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            if lhs.projectName != rhs.projectName {
                return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
            }
            return lhs.tool.rawValue < rhs.tool.rawValue
        }
    }

    private struct Project {
        let name: String
        let path: String
        let modifiedAt: Date
    }

    private func discoverProjects() -> [Project] {
        let fm = FileManager.default
        let devRoot = (NSHomeDirectory() as NSString).appendingPathComponent("dev")
        guard fm.fileExists(atPath: devRoot) else { return [] }

        var seen = Set<String>()
        var projects: [Project] = []

        func scanChildren(of root: String, depth: Int) {
            guard depth <= 1,
                  let urls = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else { return }

            for url in urls {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = url.lastPathComponent
                if Self.shouldSkipDirectory(name) { continue }

                let path = url.path
                if Self.isProjectRoot(path), seen.insert(path).inserted {
                    projects.append(Project(
                        name: Self.projectName(for: path, devRoot: devRoot),
                        path: path,
                        modifiedAt: Self.modifiedDate(for: path)
                    ))
                }
                scanChildren(of: path, depth: depth + 1)
            }
        }

        scanChildren(of: devRoot, depth: 0)
        return Array(projects.prefix(250))
    }

    private static func isProjectRoot(_ path: String) -> Bool {
        let fm = FileManager.default
        let markers = [
            ".git",
            "AGENTS.md",
            "CLAUDE.md",
            "Package.swift",
            "package.json",
            "pyproject.toml",
            "Cargo.toml",
            "go.mod",
        ]
        return markers.contains { fm.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
    }

    private static func projectName(for path: String, devRoot: String) -> String {
        guard path.hasPrefix(devRoot + "/") else {
            return (path as NSString).lastPathComponent
        }
        return String(path.dropFirst(devRoot.count + 1))
    }

    private static func modifiedDate(for path: String) -> Date {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        let probePath = FileManager.default.fileExists(atPath: gitPath) ? gitPath : path
        let attrs = try? FileManager.default.attributesOfItem(atPath: probePath)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    private static func shouldSkipDirectory(_ name: String) -> Bool {
        [
            ".build",
            ".claude",
            ".git",
            ".worktrees",
            "build",
            "dist",
            "node_modules",
            "Pods",
        ].contains(name)
    }

    private static func commandIsAvailable(_ name: String) -> Bool {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = envPath.split(separator: ":").map(String.init)
        let commonDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        ]
        for dir in pathDirs + commonDirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return true }
        }
        return false
    }
}

enum AgentRecents {
    private static let key = "launcher.agent.recents"
    private static let maxCount = 30

    static func load() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    static func record(_ id: String) {
        var items = load().filter { $0 != id }
        items.insert(id, at: 0)
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        UserDefaults.standard.set(items, forKey: key)
    }
}

final class TerminalCommandLauncher {
    static let shared = TerminalCommandLauncher()

    private let terminalBundleIDs = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]

    private var lastTerminalBundleID: String?
    private var isTracking = false

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        lastTerminalBundleID = UserDefaults.standard.string(forKey: "launcher.lastTerminalBundleID")
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  self.terminalBundleIDs.contains(bundleID) else { return }
            self.lastTerminalBundleID = bundleID
            UserDefaults.standard.set(bundleID, forKey: "launcher.lastTerminalBundleID")
        }
    }

    @discardableResult
    func run(command: String, workdir: String) -> Bool {
        startTracking()
        if let bundleID = preferredTerminalBundleID(), runInExistingTerminal(bundleID: bundleID, command: command) {
            return true
        }
        return runInNewGhosttyWindow(command: command, workdir: workdir)
    }

    private func preferredTerminalBundleID() -> String? {
        if let lastTerminalBundleID,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: lastTerminalBundleID) != nil {
            return lastTerminalBundleID
        }
        return terminalBundleIDs.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    private func runInExistingTerminal(bundleID: String, command: String) -> Bool {
        switch bundleID {
        case "com.googlecode.iterm2":
            return runAppleScript("""
            tell application id "\(bundleID)"
                activate
                if (count of windows) = 0 then
                    create window with default profile command "\(Self.appleScriptString(command))"
                else
                    tell current window to create tab with default profile command "\(Self.appleScriptString(command))"
                end if
            end tell
            """)
        case "com.apple.Terminal":
            return runViaSystemEvents(bundleID: bundleID, command: command, targetName: "Terminal")
        default:
            return runViaSystemEvents(bundleID: bundleID, command: command, targetName: "terminal")
        }
    }

    private func runViaSystemEvents(bundleID: String, command: String, targetName: String) -> Bool {
        runAppleScript("""
        tell application id "\(bundleID)" to activate
        delay 0.12
        tell application "System Events"
            keystroke "t" using command down
            delay 0.12
            keystroke "\(Self.appleScriptString(command))"
            key code 36
        end tell
        """)
    }

    private func runInNewGhosttyWindow(command: String, workdir: String) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [
            "-na",
            "Ghostty.app",
            "--args",
            "--working-directory=\(workdir)",
            "-e",
            "/bin/zsh",
            "-lc",
            "\(command); exec /bin/zsh -l",
        ]
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
    }

    private func runAppleScript(_ script: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
