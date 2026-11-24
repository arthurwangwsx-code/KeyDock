import Foundation

public enum WindowLayout: String, Codable, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, nextDisplay, previousDisplay, restore
    public var titleKey: String {
        switch self {
        case .leftHalf: "Window: Left half"
        case .rightHalf: "Window: Right half"
        case .topHalf: "Window: Top half"
        case .bottomHalf: "Window: Bottom half"
        case .topLeft: "Window: Top left"
        case .topRight: "Window: Top right"
        case .bottomLeft: "Window: Bottom left"
        case .bottomRight: "Window: Bottom right"
        case .maximize: "Window: Maximize"
        case .center: "Window: Center"
        case .nextDisplay: "Window: Next display"
        case .previousDisplay: "Window: Previous display"
        case .restore: "Window: Restore"
        }
    }
}

/// 坐标统一为AX全局左上原点；纯几何不读取屏幕或窗口。
public struct WindowFrame: Codable, Hashable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public func approximatelyEquals(_ other: Self, tolerance: Double = 3) -> Bool {
        abs(x-other.x) <= tolerance && abs(y-other.y) <= tolerance && abs(width-other.width) <= tolerance && abs(height-other.height) <= tolerance
    }
}
public struct DisplayGeometry: Sendable {
    public let id: String
    public let visibleFrame: WindowFrame
    public init(id: String, visibleFrame: WindowFrame) { self.id = id; self.visibleFrame = visibleFrame }
}
public enum WindowGeometryError: Error, Equatable { case invalidGeometry, noDisplays, noRestoreFrame, minimumExceedsDisplay }
public enum WindowGeometry {
    public static func displayIndex(for frame: WindowFrame, displays: [DisplayGeometry]) throws -> Int {
        guard frame.valid, displays.allSatisfy({ $0.visibleFrame.valid }), Set(displays.map(\.id)).count == displays.count else { throw WindowGeometryError.invalidGeometry }
        guard !displays.isEmpty else { throw WindowGeometryError.noDisplays }
        return displays.indices.max { lhs, rhs in
            let a = overlap(frame, displays[lhs].visibleFrame), b = overlap(frame, displays[rhs].visibleFrame)
            if a != b { return a < b }
            let da = distance(frame, displays[lhs].visibleFrame), db = distance(frame, displays[rhs].visibleFrame)
            return da == db ? lhs > rhs : da > db
        }!
    }
    public static func frame(for layout: WindowLayout, current: WindowFrame, displays: [DisplayGeometry],
                             minimumWidth: Double = 1, minimumHeight: Double = 1, restore: WindowFrame? = nil) throws -> WindowFrame {
        guard minimumWidth.isFinite, minimumHeight.isFinite, minimumWidth > 0, minimumHeight > 0 else { throw WindowGeometryError.invalidGeometry }
        var index = try displayIndex(for: layout == .restore ? (restore ?? current) : current, displays: displays)
        if layout == .nextDisplay { index = (index + 1) % displays.count }
        if layout == .previousDisplay { index = (index + displays.count - 1) % displays.count }
        let area = displays[index].visibleFrame
        guard minimumWidth <= area.width, minimumHeight <= area.height else { throw WindowGeometryError.minimumExceedsDisplay }
        var result = area
        switch layout {
        case .restore:
            guard let restore, restore.valid else { throw WindowGeometryError.noRestoreFrame }; result = restore
        case .center:
            result.width = min(current.width, area.width); result.height = min(current.height, area.height)
            result.x = area.x + (area.width-result.width)/2; result.y = area.y + (area.height-result.height)/2
        case .nextDisplay, .previousDisplay:
            let source = displays[try displayIndex(for: current, displays: displays)].visibleFrame
            result.width = min(current.width, area.width); result.height = min(current.height, area.height)
            let rx = min(1, max(0, (current.x-source.x)/max(1,source.width-current.width)))
            let ry = min(1, max(0, (current.y-source.y)/max(1,source.height-current.height)))
            result.x = area.x + rx*(area.width-result.width); result.y = area.y + ry*(area.height-result.height)
        case .maximize: break
        default:
            if [.leftHalf,.rightHalf,.topLeft,.topRight,.bottomLeft,.bottomRight].contains(layout) { result.width /= 2 }
            if [.topHalf,.bottomHalf,.topLeft,.topRight,.bottomLeft,.bottomRight].contains(layout) { result.height /= 2 }
            if [.rightHalf,.topRight,.bottomRight].contains(layout) { result.x += area.width/2 }
            if [.bottomHalf,.bottomLeft,.bottomRight].contains(layout) { result.y += area.height/2 }
        }
        result.width = max(minimumWidth, min(result.width,area.width)); result.height = max(minimumHeight,min(result.height,area.height))
        result.x = min(max(result.x,area.x),area.x+area.width-result.width)
        result.y = min(max(result.y,area.y),area.y+area.height-result.height)
        return result
    }
    private static func overlap(_ a: WindowFrame, _ b: WindowFrame) -> Double {
        max(0,min(a.x+a.width,b.x+b.width)-max(a.x,b.x))*max(0,min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
    }
    private static func distance(_ a: WindowFrame, _ b: WindowFrame) -> Double {
        hypot(a.x+a.width/2-b.x-b.width/2,a.y+a.height/2-b.y-b.height/2)
    }
}
