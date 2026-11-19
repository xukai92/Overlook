import Foundation
import CoreGraphics

@main
struct WindowGeometryTests {
    static func main() {
        let baseline = CGRect(x: 120, y: 90, width: 1024, height: 740)
        var frame = baseline
        for _ in 0..<100 {
            frame = RemoteWindowGeometry.changingSidebar(in: frame, from: 0, to: 273)
            precondition(frame == CGRect(x: 120, y: 90, width: 1297, height: 740))
            precondition(frame.width - 273 == baseline.width, "Video width changed on open")
            frame = RemoteWindowGeometry.changingSidebar(in: frame, from: 273, to: 0)
            precondition(frame == baseline, "Sidebar frame drift")
        }

        // Rapid clicks use an outstanding target rather than a frame that AppKit
        // may have temporarily enlarged for content minimums.
        let pendingOpen = RemoteWindowGeometry.changingSidebar(in: baseline, from: 0, to: 273)
        let pendingClose = RemoteWindowGeometry.changingSidebar(in: pendingOpen, from: 273, to: 0)
        precondition(pendingClose == baseline)

        let resolution = CGSize(width: 1920, height: 1200)
        let content = CGSize(width: 1024, height: 712) // 28-point titlebar.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let native = RemoteWindowGeometry.sizedForVideo(
            frame: baseline, contentSize: content, videoResolution: resolution,
            sidebarWidth: 273, availableScreen: screen, mode: .nativeResolution
        )
        precondition(native.width - 273 == 1920)
        precondition(native.height - 28 == 1200)
        precondition(native.minX == baseline.minX && native.maxY == baseline.maxY)
        precondition(native.width > screen.width, "Native size must not silently shrink to fit")

        let nativeWithoutSidebar = RemoteWindowGeometry.sizedForVideo(
            frame: baseline, contentSize: content, videoResolution: resolution,
            sidebarWidth: 0, availableScreen: screen, mode: .nativeResolution
        )
        precondition(nativeWithoutSidebar.width == 1920 && nativeWithoutSidebar.height == 1228)

        let fitted = RemoteWindowGeometry.sizedForVideo(
            frame: baseline, contentSize: content, videoResolution: resolution,
            sidebarWidth: 273, availableScreen: screen, mode: .fitDisplay
        )
        precondition(screen.contains(fitted), "Fit-to-screen window goes offscreen")
        precondition(fitted.width - 273 <= resolution.width && fitted.height - 28 <= resolution.height)

        let secondScreen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let fittedOnSecondScreen = RemoteWindowGeometry.sizedForVideo(
            frame: baseline, contentSize: content, videoResolution: resolution,
            sidebarWidth: 273, availableScreen: secondScreen, mode: .fitDisplay
        )
        precondition(secondScreen.contains(fittedOnSecondScreen))
        print("PASS: 100 sidebar round trips, pending targets, native logical resolution, fit-to-screen, secondary screen")
    }
}
