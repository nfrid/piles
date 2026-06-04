import AppKit

package struct AccentPalette: Equatable {
    package var colorHex: String?

    package var primary: NSColor {
        if let colorHex, let color = ConfigColorParser.color(fromHex: colorHex) {
            return color
        }
        return ConfigColorParser.defaultNeutral
    }
}

package struct WorkspaceAppearance: Equatable {
    package var name: String?
    package var colorHex: String?

    package static let empty = WorkspaceAppearance()

    package var nsColor: NSColor? {
        guard let colorHex else { return nil }
        return ConfigColorParser.color(fromHex: colorHex)
    }
}

/// Resolved labels and accent for one workspace, built from config at UI capture time.
package struct WorkspaceUIStyle: Equatable {
    package let displayName: String
    package let workspaceColorHex: String?
    package let accentColorHex: String?

    package var accent: NSColor {
        if let workspaceColorHex, let color = ConfigColorParser.color(fromHex: workspaceColorHex) {
            return color
        }
        if let accentColorHex, let color = ConfigColorParser.color(fromHex: accentColorHex) {
            return color
        }
        return ConfigColorParser.defaultNeutral
    }
}

package struct AppearanceSnapshot: Equatable {
    package var accent: AccentPalette
    package var workspaces: [WorkspaceAppearance]

    package func workspace(at index: Int) -> WorkspaceAppearance {
        guard index >= 0, index < workspaces.count else { return .empty }
        return workspaces[index]
    }

    package func uiStyle(forWorkspace index: Int) -> WorkspaceUIStyle {
        let workspace = workspace(at: index)
        let displayName = workspace.name ?? "Workspace \(index + 1)"
        return WorkspaceUIStyle(
            displayName: displayName,
            workspaceColorHex: workspace.colorHex,
            accentColorHex: accent.colorHex
        )
    }
}

package enum ConfigColorParser {
    package static let defaultNeutral = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 230/255, green: 230/255, blue: 235/255, alpha: 1)
            : NSColor(red: 26/255, green: 34/255, blue: 37/255, alpha: 1)
    }

    package static func parse(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            return normalizedHex(trimmed)
        }
        return namedColors[trimmed]
    }

    package static func color(fromHex hex: String) -> NSColor? {
        guard let components = rgbaComponents(fromHex: hex) else { return nil }
        return NSColor(
            red: components.r,
            green: components.g,
            blue: components.b,
            alpha: components.a
        )
    }

    private static let namedColors: [String: String] = [
        "red": "#FF3B30",
        "orange": "#FF9500",
        "yellow": "#FFCC00",
        "green": "#34C759",
        "mint": "#00C7BE",
        "teal": "#30B0C7",
        "cyan": "#32ADE6",
        "blue": "#007AFF",
        "indigo": "#5856D6",
        "purple": "#AF52DE",
        "pink": "#FF2D55",
        "brown": "#A2845E",
        "gray": "#8E8E93",
        "grey": "#8E8E93",
    ]

    private static func normalizedHex(_ value: String) -> String? {
        var hex = String(value.dropFirst())
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }

        if hex.count == 3 {
            hex = hex.map { String($0) + String($0) }.joined()
        }

        if hex.count == 8 {
            return "#\(hex.uppercased())"
        }

        return "#\(hex.uppercased())"
    }

    private static func rgbaComponents(fromHex hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let normalized = normalizedHex(hex.hasPrefix("#") ? hex : "#\(hex)") else { return nil }
        let body = String(normalized.dropFirst())
        guard body.count == 6 || body.count == 8 else { return nil }

        func channel(_ start: String.Index) -> CGFloat? {
            let end = body.index(start, offsetBy: 2)
            guard let value = UInt8(body[start..<end], radix: 16) else { return nil }
            return CGFloat(value) / 255
        }

        let start = body.startIndex
        guard let r = channel(start),
              let g = channel(body.index(start, offsetBy: 2)),
              let b = channel(body.index(start, offsetBy: 4))
        else { return nil }

        let alpha: CGFloat
        if body.count == 8 {
            guard let a = channel(body.index(start, offsetBy: 6)) else { return nil }
            alpha = a
        } else {
            alpha = 1
        }

        return (r, g, b, alpha)
    }
}

package extension NSColor {
    var contrastingTextColor: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return .black }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}

package extension Config {
    var appearanceSnapshot: AppearanceSnapshot {
        AppearanceSnapshot(accent: accent, workspaces: workspaceAppearances)
    }
}
