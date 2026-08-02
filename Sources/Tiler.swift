import Foundation

package enum Layout {
    case tile
    case monocle
}

package struct LayoutSettings {
    package static let minimumMasterRatio: CGFloat = 0.10
    package static let maximumMasterRatio: CGFloat = 0.90

    let masterRatio: CGFloat

    package init(masterRatio: CGFloat = 0.55) {
        self.masterRatio = Self.clampedMasterRatio(masterRatio)
    }

    package static func clampedMasterRatio(_ ratio: CGFloat) -> CGFloat {
        guard ratio.isFinite else { return 0.55 }
        return min(max(ratio, minimumMasterRatio), maximumMasterRatio)
    }
}

package enum Tiler {
    package static func calculateFrames(
        count: Int,
        screen: CGRect,
        layout: Layout,
        settings: LayoutSettings = LayoutSettings()
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        switch layout {
        case .tile: return tileFrames(count: count, screen: screen, settings: settings)
        case .monocle: return monocleFrames(count: count, screen: screen)
        }
    }

    private static func tileFrames(count: Int, screen: CGRect, settings: LayoutSettings) -> [CGRect] {
        if count == 1 {
            return [screen]
        }

        var result: [CGRect] = []
        result.reserveCapacity(count)
        let masterWidth = floor(screen.width * settings.masterRatio)
        result.append(CGRect(
            x: screen.origin.x, y: screen.origin.y,
            width: masterWidth, height: screen.height
        ))

        let stackCount = count - 1
        let stackWidth = screen.width - masterWidth
        let stackHeight = floor(screen.height / CGFloat(stackCount))

        for i in 1..<count {
            let y = screen.origin.y + CGFloat(i - 1) * stackHeight
            let h = (i == count - 1)
                ? screen.height - CGFloat(i - 1) * stackHeight
                : stackHeight
            result.append(CGRect(
                x: screen.origin.x + masterWidth, y: y,
                width: stackWidth, height: h
            ))
        }
        return result
    }

    private static func monocleFrames(count: Int, screen: CGRect) -> [CGRect] {
        Array(repeating: screen, count: count)
    }
}
