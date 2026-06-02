import Cocoa

package struct Binding {
    let key: UInt16
    let shift: Bool
    let command: String

    init(key: UInt16, shift: Bool = false, command: String) {
        self.key = key
        self.shift = shift
        self.command = command
    }
}

package enum Key {
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51

    static let a: UInt16 = 0
    static let b: UInt16 = 11
    static let c: UInt16 = 8
    static let d: UInt16 = 2
    static let e: UInt16 = 14
    static let f: UInt16 = 3
    static let g: UInt16 = 5
    static let h: UInt16 = 4
    static let i: UInt16 = 34
    static let j: UInt16 = 38
    static let k: UInt16 = 40
    static let l: UInt16 = 37
    static let m: UInt16 = 46
    static let n: UInt16 = 45
    static let o: UInt16 = 31
    static let p: UInt16 = 35
    static let q: UInt16 = 12
    static let r: UInt16 = 15
    static let s: UInt16 = 1
    static let t: UInt16 = 17
    static let u: UInt16 = 32
    static let v: UInt16 = 9
    static let w: UInt16 = 13
    static let x: UInt16 = 7
    static let y: UInt16 = 16
    static let z: UInt16 = 6

    static let zero: UInt16 = 29
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
    static let six: UInt16 = 22
    static let seven: UInt16 = 26
    static let eight: UInt16 = 28
    static let nine: UInt16 = 25

    static let minus: UInt16 = 27
    static let equal: UInt16 = 24
    static let leftBracket: UInt16 = 33
    static let rightBracket: UInt16 = 30
    static let semicolon: UInt16 = 41
    static let quote: UInt16 = 39
    static let comma: UInt16 = 43
    static let period: UInt16 = 47
    static let slash: UInt16 = 44
    static let backslash: UInt16 = 42
    static let grave: UInt16 = 50

    static let byName: [String: UInt16] = [
        "return": Key.return, "tab": Key.tab, "space": Key.space,
        "escape": Key.escape, "delete": Key.delete,
        "a": Key.a, "b": Key.b, "c": Key.c, "d": Key.d, "e": Key.e,
        "f": Key.f, "g": Key.g, "h": Key.h, "i": Key.i, "j": Key.j,
        "k": Key.k, "l": Key.l, "m": Key.m, "n": Key.n, "o": Key.o,
        "p": Key.p, "q": Key.q, "r": Key.r, "s": Key.s, "t": Key.t,
        "u": Key.u, "v": Key.v, "w": Key.w, "x": Key.x, "y": Key.y,
        "z": Key.z,
        "0": Key.zero, "1": Key.one, "2": Key.two, "3": Key.three,
        "4": Key.four, "5": Key.five, "6": Key.six, "7": Key.seven,
        "8": Key.eight, "9": Key.nine,
        "minus": Key.minus, "equal": Key.equal,
        "leftbracket": Key.leftBracket, "rightbracket": Key.rightBracket,
        "semicolon": Key.semicolon, "quote": Key.quote,
        "comma": Key.comma, "period": Key.period,
        "slash": Key.slash, "backslash": Key.backslash, "grave": Key.grave,
    ]

    static let numberKeys: [UInt16] = [
        Key.one, Key.two, Key.three, Key.four, Key.five,
        Key.six, Key.seven, Key.eight, Key.nine,
    ]
}

package struct BuiltinBindings {
    var focusNext: (key: UInt16, shift: Bool) = (Key.j, false)
    var focusPrev: (key: UInt16, shift: Bool) = (Key.k, false)
    var moveNext: (key: UInt16, shift: Bool) = (Key.j, true)
    var movePrev: (key: UInt16, shift: Bool) = (Key.k, true)
    var workspaceNext: (key: UInt16, shift: Bool) = (Key.l, false)
    var workspacePrev: (key: UInt16, shift: Bool) = (Key.h, false)
    var swapMaster: (key: UInt16, shift: Bool) = (Key.return, false)
    var toggleLayout: (key: UInt16, shift: Bool) = (Key.m, false)
    var focusMonitorPrev: (key: UInt16, shift: Bool) = (Key.comma, false)
    var focusMonitorNext: (key: UInt16, shift: Bool) = (Key.period, false)
    var moveMonitorPrev: (key: UInt16, shift: Bool) = (Key.comma, true)
    var moveMonitorNext: (key: UInt16, shift: Bool) = (Key.period, true)
    var lastWorkspace: (key: UInt16, shift: Bool) = (Key.tab, false)
}

private typealias BuiltinBindingKeyPath = WritableKeyPath<BuiltinBindings, (key: UInt16, shift: Bool)>

private let builtinBindingKeys: [(name: String, keyPath: BuiltinBindingKeyPath)] = [
    ("focus_next", \.focusNext),
    ("focus_prev", \.focusPrev),
    ("move_next", \.moveNext),
    ("move_prev", \.movePrev),
    ("workspace_next", \.workspaceNext),
    ("workspace_prev", \.workspacePrev),
    ("swap_master", \.swapMaster),
    ("toggle_layout", \.toggleLayout),
    ("focus_monitor_prev", \.focusMonitorPrev),
    ("focus_monitor_next", \.focusMonitorNext),
    ("move_monitor_prev", \.moveMonitorPrev),
    ("move_monitor_next", \.moveMonitorNext),
    ("last_workspace", \.lastWorkspace),
]

package struct WindowAssignment {
    let app: String?
    let bundleID: String?
    let title: String?
    let titleContains: String?
    let monitor: Int?
    let workspace: Int?
    let position: Int?

    package init(
        app: String? = nil,
        bundleID: String? = nil,
        title: String? = nil,
        titleContains: String? = nil,
        monitor: Int? = nil,
        workspace: Int? = nil,
        position: Int? = nil
    ) {
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.titleContains = titleContains
        self.monitor = monitor
        self.workspace = workspace
        self.position = position
    }

    func matches(app: String?, bundleID: String?, title: String?) -> Bool {
        if let expected = self.app, expected != app { return false }
        if let expected = self.bundleID, expected != bundleID { return false }
        if let expected = self.title, expected != title { return false }
        if let needle = titleContains, title?.range(of: needle) == nil { return false }

        return self.app != nil
            || self.bundleID != nil
            || self.title != nil
            || self.titleContains != nil
    }
}

package struct Config {
    package static var shared = Config()

    package var workspaceCount: Int = 9
    package var masterRatio: CGFloat = 0.55
    package var defaultLayout: Layout = .monocle
    package var modifier: CGEventFlags = .maskAlternate
    package var customBindings: [Binding] = [
        Binding(key: Key.return, shift: true, command: "open -n -a Terminal"),
    ]
    package var assignments: [WindowAssignment] = []
    package var bindings = BuiltinBindings()

    package fileprivate(set) var numberKeys: [UInt16: Int] = buildNumberKeys(count: 9)

    fileprivate static func buildNumberKeys(count: Int) -> [UInt16: Int] {
        var map: [UInt16: Int] = [:]
        for i in 0..<count { map[Key.numberKeys[i]] = i + 1 }
        return map
    }

    package static func load() {
        let path = NSString("~/.config/piles/config.toml").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            shared = Config()
            return
        }

        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            fputs("piles: failed to read config file\n", stderr)
            return
        }

        load(text: text)
    }

    package static func load(text: String) {
        guard let config = ConfigParser.parse(text: text, diagnose: {
            fputs("piles: \($0)\n", stderr)
        }) else {
            return
        }
        shared = config
    }

    package func assignment(app: String?, bundleID: String?, title: String?) -> WindowAssignment? {
        assignments.first { $0.matches(app: app, bundleID: bundleID, title: title) }
    }
}

package enum ConfigParser {
    package typealias DiagnosticSink = (String) -> Void

    package static func parse(text: String, diagnose: DiagnosticSink = { _ in }) -> Config? {
        let toml: [String: Any]
        do {
            toml = try Toml.parse(text)
        } catch {
            diagnose("config parse error: \(error)")
            return nil
        }

        return parse(toml: toml, diagnose: diagnose)
    }

    static func parse(toml: [String: Any], diagnose: DiagnosticSink = { _ in }) -> Config {
        var config = Config()

        applyWorkspaceCount(toml["workspace_count"], to: &config, diagnose: diagnose)
        applyMasterRatio(toml["master_ratio"], to: &config, diagnose: diagnose)
        applyDefaultLayout(toml["default_layout"], to: &config, diagnose: diagnose)
        applyModifier(toml["modifier"], to: &config, diagnose: diagnose)

        if let bindings = toml["bindings"] as? [String: Any] {
            applyBindings(bindings, to: &config.bindings, diagnose: diagnose)
        }

        if let customs = toml["custom"] as? [[String: Any]] {
            config.customBindings = parseCustomBindings(customs, diagnose: diagnose)
        }

        if let assignments = toml["assign"] as? [[String: Any]] {
            config.assignments = parseAssignments(
                assignments,
                workspaceCount: config.workspaceCount,
                diagnose: diagnose
            )
        }

        return config
    }

    private static func applyWorkspaceCount(_ value: Any?, to config: inout Config, diagnose: DiagnosticSink) {
        guard let value else { return }
        guard let count = value as? Int, count >= 1, count <= 9 else {
            diagnose("workspace_count must be between 1 and 9, using 9")
            return
        }
        config.workspaceCount = count
        config.numberKeys = Config.buildNumberKeys(count: count)
    }

    private static func applyMasterRatio(_ value: Any?, to config: inout Config, diagnose: DiagnosticSink) {
        guard let value else { return }
        guard let ratio = value as? Double, ratio >= 0, ratio <= 1 else {
            diagnose("master_ratio must be between 0.0 and 1.0, using 0.55")
            return
        }
        config.masterRatio = CGFloat(ratio)
    }

    private static func applyDefaultLayout(_ value: Any?, to config: inout Config, diagnose: DiagnosticSink) {
        guard let layout = value as? String else { return }
        switch layout {
        case "tile": config.defaultLayout = .tile
        case "monocle": config.defaultLayout = .monocle
        default: diagnose("unknown default_layout '\(layout)', using monocle")
        }
    }

    private static func applyModifier(_ value: Any?, to config: inout Config, diagnose: DiagnosticSink) {
        guard let modifier = value as? String else { return }
        switch modifier {
        case "option": config.modifier = .maskAlternate
        case "control": config.modifier = .maskControl
        case "command": config.modifier = .maskCommand
        default: diagnose("unknown modifier '\(modifier)', using option")
        }
    }

    private static func parseCustomBindings(_ entries: [[String: Any]], diagnose: DiagnosticSink) -> [Binding] {
        entries.compactMap { entry in
            guard let keyStr = entry["key"] as? String,
                  let command = entry["command"] as? String
            else { return nil }

            let (keyCode, shift) = parseKeyString(keyStr)
            guard let code = keyCode else {
                diagnose("unknown key '\(keyStr)' in custom binding")
                return nil
            }
            return Binding(key: code, shift: shift, command: command)
        }
    }

    private static func parseAssignments(
        _ entries: [[String: Any]],
        workspaceCount: Int,
        diagnose: DiagnosticSink
    ) -> [WindowAssignment] {
        entries.compactMap { entry in
            let app = entry["app"] as? String
            let bundleID = entry["bundle_id"] as? String
            let title = entry["title"] as? String
            let titleContains = entry["title_contains"] as? String

            guard app != nil || bundleID != nil || title != nil || titleContains != nil else {
                diagnose("assignment needs app, bundle_id, title, or title_contains")
                return nil
            }

            let monitor = positiveInt(entry["monitor"], name: "monitor", diagnose: diagnose)
            let workspace = workspaceIndex(entry["workspace"], max: workspaceCount, diagnose: diagnose)
            let position = positiveInt(entry["position"], name: "position", diagnose: diagnose)

            return WindowAssignment(
                app: app,
                bundleID: bundleID,
                title: title,
                titleContains: titleContains,
                monitor: monitor,
                workspace: workspace,
                position: position
            )
        }
    }

    private static func parseKeyString(_ s: String) -> (key: UInt16?, shift: Bool) {
        if s.hasPrefix("shift+") {
            let name = String(s.dropFirst(6))
            return (Key.byName[name], true)
        }
        return (Key.byName[s], false)
    }

    private static func applyBindings(_ dict: [String: Any], to bindings: inout BuiltinBindings, diagnose: DiagnosticSink) {
        for bindingKey in builtinBindingKeys {
            guard let value = dict[bindingKey.name] as? String else { continue }
            let (keyCode, shift) = parseKeyString(value)
            guard let code = keyCode else {
                diagnose("unknown key '\(value)' for binding '\(bindingKey.name)'")
                continue
            }
            bindings[keyPath: bindingKey.keyPath] = (code, shift)
        }
    }

    private static func workspaceIndex(_ value: Any?, max: Int, diagnose: DiagnosticSink) -> Int? {
        guard let workspace = value as? Int else { return nil }
        guard workspace >= 1, workspace <= max else {
            diagnose("assignment workspace must be between 1 and \(max)")
            return nil
        }
        return workspace
    }

    private static func positiveInt(_ value: Any?, name: String, diagnose: DiagnosticSink) -> Int? {
        guard let int = value as? Int else { return nil }
        guard int >= 1 else {
            diagnose("assignment \(name) must be at least 1")
            return nil
        }
        return int
    }
}
