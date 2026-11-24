import Testing
@testable import CommandCore

struct WindowGeometryTests {
    let displays = [DisplayGeometry(id:"left",visibleFrame:.init(x:-1200,y:30,width:1200,height:800)), DisplayGeometry(id:"main",visibleFrame:.init(x:0,y:30,width:1600,height:1000))]
    @Test func choosesMaximumIntersectionAndNearestDisconnectedFrame() throws {
        #expect(try WindowGeometry.displayIndex(for:.init(x:-200,y:50,width:900,height:600),displays:displays) == 1)
        #expect(try WindowGeometry.displayIndex(for:.init(x:-3000,y:50,width:500,height:400),displays:displays) == 0)
    }
    @Test func cornersRespectVisibleAreaAndNegativeOrigins() throws {
        let frame = try WindowGeometry.frame(for:.bottomRight,current:.init(x:-1000,y:60,width:500,height:400),displays:displays)
        #expect(frame == .init(x:-600,y:430,width:600,height:400))
    }
    @Test func restoreClampsRemovedDisplayAndHonorsMinimumSize() throws {
        let old = WindowFrame(x:-2000,y:-400,width:400,height:200)
        let frame = try WindowGeometry.frame(for:.restore,current:.init(x:100,y:80,width:800,height:600),displays:[displays[1]],minimumWidth:600,minimumHeight:400,restore:old)
        #expect(frame == .init(x:0,y:30,width:600,height:400))
        #expect(throws:WindowGeometryError.minimumExceedsDisplay) { try WindowGeometry.frame(for:.leftHalf,current:old,displays:displays,minimumWidth:3000) }
    }
    @Test func crossDisplayPreservesRelativePositionAndWraps() throws {
        let current = WindowFrame(x:1100,y:600,width:500,height:400)
        let next = try WindowGeometry.frame(for:.nextDisplay,current:current,displays:displays)
        #expect(next.x == -500 && next.y == 410 && next.width == 500)
        let back = try WindowGeometry.frame(for:.previousDisplay,current:next,displays:displays)
        #expect(back.approximatelyEquals(current))
    }
    @Test func rejectsInvalidGeometryAndMissingRestore() throws {
        #expect(throws:WindowGeometryError.invalidGeometry) { try WindowGeometry.displayIndex(for:.init(x:.nan,y:0,width:5,height:5),displays:displays) }
        #expect(throws:WindowGeometryError.noRestoreFrame) { try WindowGeometry.frame(for:.restore,current:.init(x:0,y:0,width:5,height:5),displays:displays) }
    }
}
