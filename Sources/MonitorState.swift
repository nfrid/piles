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
    var workspaces: [[TrackedWindow]]
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

    mutating func insertWindow(_ window: TrackedWindow, workspace: Int? = nil, position: Int? = nil) {
        let workspaceIndex = resolvedWorkspaceIndex(workspace)
        let insertIndex = resolvedInsertIndex(position, in: workspaceIndex)
        workspaces[workspaceIndex].insert(window, at: insertIndex)
    }

    mutating func removeActiveWindow(matching focused: TrackedWindow) -> TrackedWindow? {
        guard let index = workspaces[active].firstIndex(of: focused) else { return nil }
        return workspaces[active].remove(at: index)
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
        return (changed, activeChanged)
    }

    mutating func rememberFocusedWindow(_ focused: TrackedWindow) -> Bool {
        guard let index = workspaces[active].firstIndex(of: focused) else { return false }
        workspaces[active][index] = focused.keepingMembers(from: workspaces[active][index])
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
