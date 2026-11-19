import Foundation
import CoreGraphics

/// Sizes are macOS logical points; native resolution intentionally treats each
/// remote pixel as one point, as requested for this client's display workflow.
enum RemoteWindowSizeMode {
    case nativeResolution
    case fitDisplay
}

enum RemoteWindowGeometry {
    static func changingSidebar(in frame: CGRect, from oldWidth: CGFloat, to newWidth: CGFloat) -> CGRect {
        var target = frame
        target.size.width = frame.width - oldWidth + newWidth
        return target
    }

    static func sizedForVideo(
        frame: CGRect,
        contentSize: CGSize,
        videoResolution: CGSize,
        sidebarWidth: CGFloat,
        availableScreen: CGRect?,
        mode: RemoteWindowSizeMode
    ) -> CGRect {
        guard videoResolution.width > 0, videoResolution.height > 0 else { return frame }
        let chromeWidth = frame.width - contentSize.width
        let chromeHeight = frame.height - contentSize.height
        var videoSize = videoResolution
        if mode == .fitDisplay, let availableScreen {
            let availableWidth = max(1, availableScreen.width - chromeWidth - sidebarWidth)
            let availableHeight = max(1, availableScreen.height - chromeHeight)
            let scale = min(1, availableWidth / videoSize.width, availableHeight / videoSize.height)
            videoSize = CGSize(width: floor(videoSize.width * scale), height: floor(videoSize.height * scale))
        }
        var target = frame
        target.size = CGSize(width: videoSize.width + chromeWidth + sidebarWidth,
                             height: videoSize.height + chromeHeight)
        target.origin.y = frame.maxY - target.height
        if mode == .fitDisplay, let availableScreen {
            target.origin.x = min(max(target.minX, availableScreen.minX), availableScreen.maxX - target.width)
            target.origin.y = min(max(target.minY, availableScreen.minY), availableScreen.maxY - target.height)
        }
        return target
    }
}
