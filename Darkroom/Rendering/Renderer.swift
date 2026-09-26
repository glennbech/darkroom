import Foundation
import CoreImage
import Metal
import MetalKit
import os.signpost

/// Signpost log for canvas / render performance timing.
/// Recorded intervals: `draw`, `evaluatePreview`, `startTask`.
/// Enable in Instruments with the "os_signpost" template, filter on
/// subsystem `no.glennbech.darkroom`, category `canvas`.
enum RenderSignpost {
    static let log = OSLog(subsystem: "no.glennbech.darkroom", category: "canvas")
}

final class SharedRenderer {
    static let shared = SharedRenderer()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let context: CIContext

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal not available")
        }
        self.device = device
        self.commandQueue = queue
        let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.context = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: workingColorSpace,
            .cacheIntermediates: true,
            .useSoftwareRenderer: false
        ])
    }
}
