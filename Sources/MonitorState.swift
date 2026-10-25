import Foundation

enum WindowUpdate {
    case missing
    case inserted
    case replaced
    case unchanged
}

enum WorkspaceWindows {
    static func afterRemoving(
        from windows: [TrackedWindow],
        focusedIndex: inout Int,
        where predicate: (TrackedWindow) -> Bool
    ) -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        result.reserveCapacity(windows.count)

        var removedBeforeFocus = 0
        var removedFocused = false
        let originalFocus = Swift.min(Swift.max(focusedIndex, 0), max(windows.count - 1, 0))

        for index in windows.indices {
            if predicate(windows[index]) {
                if index < originalFocus {
                    removedBeforeFocus += 1
                } else if index == originalFocus {
                    removedFocused = true
                }
                continue
            }
            result.append(windows[index])
        }

        guard !result.isEmpty else {
            focusedIndex = 0
            return result
        }

        let adjustedFocus = originalFocus - removedBeforeFocus
        focusedIndex = removedFocused
            ? Swift.min(adjustedFocus, result.count - 1)
            : Swift.min(Swift.max(adjustedFocus, 0), result.count - 1)
        return result
    }

    static func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index % count + count) % count
    }

    static func moveIndex(_ sourceIndex: Int, offset: Int, count: Int) -> Int {
        wrappedIndex(sourceIndex + offset, count: count)
    }

    static func moving<T>(_ items: [T], from sourceIndex: Int, offset: Int) -> (items: [T], movedIndex: Int) {
        guard items.indices.contains(sourceIndex), items.count > 1 else {
            return (items, sourceIndex)
        }

        let targetIndex = moveIndex(sourceIndex, offset: offset, count: items.count)
        guard targetIndex != sourceIndex else {
            return (items, sourceIndex)
        }

        var moved = items
        let item = moved.remove(at: sourceIndex)
        moved.insert(item, at: targetIndex)
        return (moved, targetIndex)
    }

    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2.0) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    /// Returns true when `frame` is already parked at the offscreen hide position for `screen`.
    static func isHiddenOffscreen(frame: CGRect, screen: CGRect, tolerance: CGFloat = 2.0) -> Bool {
        let targetX = screen.origin.x + 1 - screen.width
        return abs(frame.origin.x - targetX) <= tolerance
    }

    static func framePreservingSizeInsideScreen(_ frame: CGRect, screen: CGRect) -> CGRect {
        CGRect(
            origin: CGPoint(
                x: clampedOrigin(frame.minX, length: frame.width, min: screen.minX, max: screen.maxX),
                y: clampedOrigin(frame.minY, length: frame.height, min: screen.minY, max: screen.maxY)
            ),
            size: frame.size
        )
    }

    private static func clampedOrigin(_ origin: CGFloat, length: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard origin.isFinite, length.isFinite, min.isFinite, max.isFinite else { return min }
        guard length <= max - min else { return min }
        return Swift.min(Swift.max(origin, min), max - length)
    }
}

package struct MonitorState {
    struct WindowMetadata {
        var floating = false
        var parkedFrame: CGRect?
    }

    var workspaces: [[TrackedWindow]]
    private(set) var windowMetadata: [WindowIdentityKey: WindowMetadata] = [:]
    var layouts: [Layout]
    var focusedIndices: [Int]
    var active: Int
    var previousActive: Int

    init(count: Int = Config.shared.workspaceCount, defaultLayout: Layout = Config.shared.defaultLayout) {
        workspaces = Array(repeating: [], count: count)
        layouts = Array(repeating: defaultLayout, count: count)
        focusedIndices = Array(repeating: 0, count: count)
        active = 0
        previousActive = 0
    }

    mutating func activate(_ index: Int) -> Int? {
        guard workspaces.indices.contains(index), index != active else { return nil }
        let previous = active
        previousActive = previous
        active = index
        return previous
    }

    func resolvedWorkspaceIndex(_ workspace: Int?) -> Int {
        guard let workspace else { return active }
        return Swift.min(Swift.max(workspace - 1, 0), workspaces.count - 1)
    }

    func resolvedInsertIndex(_ position: Int?, in workspaceIndex: Int) -> Int {
        guard let position else { return 0 }
        return Swift.min(Swift.max(position - 1, 0), workspaces[workspaceIndex].count)
    }

    func clampedFocus(in workspaceIndex: Int) -> Int {
        guard workspaces.indices.contains(workspaceIndex) else { return 0 }
        let count = workspaces[workspaceIndex].count
        guard count > 0 else { return 0 }
        return Swift.min(Swift.max(focusedIndices[workspaceIndex], 0), count - 1)
    }

    func isFloating(_ window: TrackedWindow) -> Bool {
        window.identityKeys.contains { windowMetadata[$0]?.floating == true }
    }

    func metadata(for window: TrackedWindow) -> WindowMetadata? {
        window.identityKeys.compactMap { windowMetadata[$0] }.first
    }

    mutating func adoptMetadata(_ metadata: WindowMetadata?, for window: TrackedWindow) {
        guard let metadata else { return }
        for key in window.identityKeys { windowMetadata[key] = metadata }
    }

    func parkedFrame(for window: TrackedWindow) -> CGRect? {
        window.identityKeys.compactMap { windowMetadata[$0]?.parkedFrame }.first
    }

    mutating func setFloating(_ floating: Bool, for window: TrackedWindow) {
        var metadata = window.identityKeys.compactMap { windowMetadata[$0] }.first ?? WindowMetadata()
        metadata.floating = floating
        for key in window.identityKeys { windowMetadata[key] = metadata }
    }

    mutating func saveParkedFrame(_ frame: CGRect, for window: TrackedWindow) {
        var metadata = window.identityKeys.compactMap { windowMetadata[$0] }.first ?? WindowMetadata()
        metadata.parkedFrame = frame
        for key in window.identityKeys { windowMetadata[key] = metadata }
    }

    mutating func pruneMetadata() {
        let remaining = Set(workspaces.flatMap { $0.flatMap(\.identityKeys) })
        windowMetadata = windowMetadata.filter { remaining.contains($0.key) }
    }

    mutating func removeMetadata(for window: TrackedWindow) {
        for key in window.identityKeys { windowMetadata.removeValue(forKey: key) }
    }

    mutating func clearParkedFrame(for window: TrackedWindow) {
        for key in window.identityKeys {
            guard var metadata = windowMetadata[key] else { continue }
            metadata.parkedFrame = nil
            if !metadata.floating { windowMetadata.removeValue(forKey: key) }
            else { windowMetadata[key] = metadata }
        }
    }

    mutating func replaceWindow(_ old: TrackedWindow, with new: TrackedWindow) {
        transferMetadata(from: old, to: new)
        for workspace in workspaces.indices {
            if let index = workspaces[workspace].firstIndex(of: old) {
                workspaces[workspace][index] = new
                return
            }
        }
    }

    private mutating func transferMetadata(from old: TrackedWindow, to new: TrackedWindow) {
        guard let metadata = old.identityKeys.compactMap({ windowMetadata[$0] }).first else { return }
        for key in old.identityKeys { windowMetadata.removeValue(forKey: key) }
        for key in new.identityKeys { windowMetadata[key] = metadata }
    }

    mutating func insertWindow(_ window: TrackedWindow, workspace: Int? = nil, position: Int? = nil, floating: Bool = false) {
        let workspaceIndex = resolvedWorkspaceIndex(workspace)
        let insertIndex = resolvedInsertIndex(position, in: workspaceIndex)
        let oldCount = workspaces[workspaceIndex].count
        let oldFocus = clampedFocus(in: workspaceIndex)
        workspaces[workspaceIndex].insert(window, at: insertIndex)
        if floating { setFloating(true, for: window) }
        if oldCount == 0 {
            focusedIndices[workspaceIndex] = 0
        } else if insertIndex <= oldFocus {
            focusedIndices[workspaceIndex] = oldFocus + 1
        } else {
            focusedIndices[workspaceIndex] = oldFocus
        }
    }

    mutating func removeActiveWindow(matching focused: TrackedWindow) -> TrackedWindow? {
        guard let removedIndex = workspaces[active].firstIndex(of: focused) else { return nil }
        let oldFocus = clampedFocus(in: active)
        let removedWindow = workspaces[active].remove(at: removedIndex)
        if workspaces[active].isEmpty {
            focusedIndices[active] = 0
        } else if removedIndex < oldFocus {
            focusedIndices[active] = oldFocus - 1
        } else {
            focusedIndices[active] = Swift.min(oldFocus, workspaces[active].count - 1)
        }
        return removedWindow
    }

    mutating func moveActiveWindow(matching focused: TrackedWindow, to workspaceIndex: Int) -> TrackedWindow? {
        guard workspaces.indices.contains(workspaceIndex),
              let removed = removeActiveWindow(matching: focused)
        else { return nil }
        workspaces[workspaceIndex].insert(removed, at: 0)
        focusedIndices[workspaceIndex] = 0
        return removed
    }

    mutating func removeWindows(where predicate: (TrackedWindow) -> Bool) -> (changed: Bool, activeChanged: Bool) {
        var changed = false
        var activeChanged = false
        for index in workspaces.indices {
            let before = workspaces[index]
            workspaces[index] = WorkspaceWindows.afterRemoving(
                from: before,
                focusedIndex: &focusedIndices[index],
                where: predicate
            )
            if workspaces[index].count != before.count {
                changed = true
                activeChanged = activeChanged || index == active
            }
        }
        pruneMetadata()
        return (changed, activeChanged)
    }

    mutating func rememberFocusedWindow(_ focused: TrackedWindow) -> Bool {
        guard let index = workspaces[active].firstIndex(of: focused) else { return false }
        let old = workspaces[active][index]
        let replacement = focused.keepingMembers(from: old)
        transferMetadata(from: old, to: replacement)
        workspaces[active][index] = replacement
        focusedIndices[active] = index
        return true
    }

    mutating func resize(to count: Int, defaultLayout: Layout = Config.shared.defaultLayout) {
        let old = workspaces.count
        guard count != old else { return }

        if count > old {
            workspaces.append(contentsOf: Array(repeating: [], count: count - old))
            layouts.append(contentsOf: Array(repeating: defaultLayout, count: count - old))
            focusedIndices.append(contentsOf: Array(repeating: 0, count: count - old))
        } else {
            let overflow = workspaces[count..<old].joined()
            workspaces.removeSubrange(count...)
            layouts.removeSubrange(count...)
            focusedIndices.removeSubrange(count...)
            if active >= count {
                active = count - 1
            }
            if previousActive >= count {
                previousActive = active
            }
            workspaces[active].append(contentsOf: overflow)
        }
    }
}
