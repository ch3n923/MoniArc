@preconcurrency import MetalKit
import AppKit
import QuartzCore
import simd

@MainActor
final class HDRStatusGlowView: MTKView {
    private var glowRenderer: HDRGlowRenderer?

    var isRendererAvailable: Bool {
        glowRenderer != nil
    }

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .rgba16Float
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        preferredFramesPerSecond = 60
        framebufferOnly = true
        autoResizeDrawable = true
        wantsLayer = true
        configureMetalLayer()

        glowRenderer = HDRGlowRenderer(view: self)
        delegate = glowRenderer
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureMetalLayer()
        if isPaused, window != nil {
            draw()
        }
    }

    func update(
        appearance: ResolvedGlowAppearance,
        surfaceHeight: CGFloat,
        bottomRadius: CGFloat,
        closesTop: Bool,
        reduceMotion: Bool
    ) {
        let configuration = HDRGlowConfiguration(
            appearance: appearance,
            surfaceHeight: surfaceHeight,
            bottomRadius: bottomRadius,
            closesTop: closesTop,
            reduceMotion: reduceMotion
        )
        let needsContinuousFrames = glowRenderer?.setConfiguration(configuration) ?? false
        enableSetNeedsDisplay = !needsContinuousFrames
        isPaused = !needsContinuousFrames
        if window != nil {
            draw()
        }
    }

    func stopRendering() {
        isPaused = true
        delegate = nil
        glowRenderer = nil
    }

    private func configureMetalLayer() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.presentsWithTransaction = false
        metalLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }
}

fileprivate struct HDRGlowConfiguration: Equatable {
    var appearance: ResolvedGlowAppearance
    var surfaceHeight: CGFloat
    var bottomRadius: CGFloat
    var closesTop: Bool
    var reduceMotion: Bool

    var shouldAnimateMotion: Bool {
        appearance.isBusy && !reduceMotion
    }
}

private struct HDRGlowUniforms {
    var canvas: SIMD4<Float>
    var surfaceRect: SIMD4<Float>
    var coreColor: SIMD4<Float>
    var glowColor: SIMD4<Float>
    var animation: SIMD4<Float>
    var effects: SIMD4<Float>
    var metadata: SIMD4<Float>
}

private struct HDRGlowSegment {
    var endpoints: SIMD4<Float>
    var metrics: SIMD4<Float>
}

private struct HDRGlowGeometry {
    var surfaceHeight: CGFloat
    var bottomRadius: CGFloat
}

private struct HDRBlendSample {
    var value: Float
    var isTransitioning: Bool
}

@MainActor
fileprivate final class HDRGlowRenderer: NSObject, MTKViewDelegate {
    private static let hdrTransitionDuration: CFTimeInterval = 0.7
    private static let motionTransitionDuration: CFTimeInterval = 4

    private var configuration = HDRGlowConfiguration(
        appearance: .inactive,
        surfaceHeight: IslandDesign.collapsedHeight,
        bottomRadius: IslandDesign.floatingRadius,
        closesTop: true,
        reduceMotion: false
    )

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var hdrTarget: Float = 0
    private var hdrTransitionFrom: Float = 0
    private var hdrTransitionStartedAt: CFTimeInterval?
    private var motionTransitionFrom: GlowMotion = .breathe
    private var motionTransitionStartedAt: CFTimeInterval?

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "hdrGlowVertex"),
              let fragmentFunction = library.makeFunction(name: "hdrGlowFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MoniArc model-linked HDR status glow"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        self.commandQueue = commandQueue
        super.init()
    }

    func setConfiguration(_ newConfiguration: HDRGlowConfiguration) -> Bool {
        let now = CACurrentMediaTime()
        let currentBlend = hdrBlend(at: now).value
        let previousAppearance = configuration.appearance
        let newTarget: Float = newConfiguration.appearance.isBusy
            && newConfiguration.appearance.usesHDR ? 1 : 0

        if previousAppearance.isBusy,
           newConfiguration.appearance.isBusy,
           previousAppearance.motion != newConfiguration.appearance.motion {
            motionTransitionFrom = previousAppearance.motion
            motionTransitionStartedAt = now
        }
        configuration = newConfiguration
        if newTarget != hdrTarget {
            hdrTransitionFrom = currentBlend
            hdrTarget = newTarget
            hdrTransitionStartedAt = now
        }
        return configuration.shouldAnimateMotion
            || hdrTransitionStartedAt != nil
            || motionTransitionStartedAt != nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if view.isPaused {
            view.setNeedsDisplay(view.bounds)
        }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let blend = hdrBlend(at: now)
        let policy = configureEDR(
            for: view,
            requestsHDR: hdrTarget > 0 || blend.value > 0.0001
        )
        guard view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let scale = max(1, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let geometry = liveGeometry(in: view)
        let segments = makeSegments(scale: scale, geometry: geometry)
        guard !segments.isEmpty else { return }

        var uniforms = makeUniforms(
            canvasSize: view.drawableSize,
            scale: scale,
            segmentCount: segments.count,
            policy: policy,
            hdrBlend: blend.value,
            geometry: geometry,
            now: now
        )

        encoder.label = "Draw model-linked status outline and glow"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<HDRGlowUniforms>.stride,
            index: 0
        )
        segments.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            encoder.setFragmentBytes(
                baseAddress,
                length: buffer.count * MemoryLayout<HDRGlowSegment>.stride,
                index: 1
            )
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if !configuration.shouldAnimateMotion,
           !blend.isTransitioning,
           !isMotionTransitioning(at: now) {
            view.enableSetNeedsDisplay = true
            view.isPaused = true
        }
    }

    private func hdrBlend(at now: CFTimeInterval) -> HDRBlendSample {
        guard let startedAt = hdrTransitionStartedAt else {
            return HDRBlendSample(value: hdrTarget, isTransitioning: false)
        }

        let progress = Float(min(max((now - startedAt) / Self.hdrTransitionDuration, 0), 1))
        let value = hdrTransitionFrom + (hdrTarget - hdrTransitionFrom) * progress
        if progress >= 1 {
            hdrTransitionFrom = hdrTarget
            hdrTransitionStartedAt = nil
            return HDRBlendSample(value: hdrTarget, isTransitioning: false)
        }
        return HDRBlendSample(value: value, isTransitioning: true)
    }

    private func configureEDR(for view: MTKView, requestsHDR: Bool) -> EDRDisplayPolicy {
        let screen = view.window?.screen ?? NSScreen.main
        let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        var current = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        var policy = EDRDisplayPolicy(
            requestsHDR: requestsHDR,
            maximumPotentialHeadroom: potential,
            maximumCurrentHeadroom: current
        )

        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            // requestsHDR remains true during the complete 700 ms fade-out, so
            // the compositor cannot clamp the final transition frames early.
            metalLayer.wantsExtendedDynamicRangeContent = policy.shouldRequestEDR
            metalLayer.presentsWithTransaction = false
            metalLayer.contentsScale = view.window?.backingScaleFactor
                ?? screen?.backingScaleFactor
                ?? 2
        }

        current = screen?.maximumExtendedDynamicRangeColorComponentValue ?? current
        policy.maximumCurrentHeadroom = current
        return policy
    }

    private func makeUniforms(
        canvasSize: CGSize,
        scale: CGFloat,
        segmentCount: Int,
        policy: EDRDisplayPolicy,
        hdrBlend: Float,
        geometry: HDRGlowGeometry,
        now: CFTimeInterval
    ) -> HDRGlowUniforms {
        let levels = resolvedLevels(at: now)
        let solarFlareBlend = solarFlareBlend(at: now)
        let topInset = configuration.closesTop ? IslandDesign.glowOutset : 0
        let surfaceOrigin = SIMD2<Float>(
            Float(IslandDesign.glowOutset * scale),
            Float(topInset * scale)
        )
        let surfaceSize = SIMD2<Float>(
            Float(IslandDesign.width * scale),
            Float(geometry.surfaceHeight * scale)
        )

        return HDRGlowUniforms(
            canvas: SIMD4(
                Float(canvasSize.width),
                Float(canvasSize.height),
                Float(scale),
                configuration.closesTop ? 1 : 0
            ),
            surfaceRect: SIMD4(surfaceOrigin.x, surfaceOrigin.y, surfaceSize.x, surfaceSize.y),
            coreColor: colorComponents(themeColor),
            glowColor: colorComponents(themeColor),
            animation: SIMD4(
                levels.progress,
                0.55,
                linearHDRBrightness(levels.coreBrightness, blend: hdrBlend, policy: policy),
                linearHDRBrightness(levels.peakBrightness, blend: hdrBlend, policy: policy)
            ),
            effects: SIMD4(
                linearHDRBrightness(levels.ambientBrightness, blend: hdrBlend, policy: policy),
                Float(1.0 * scale),
                Float(geometry.bottomRadius * scale),
                levels.motionCode
            ),
            metadata: SIMD4(
                Float(segmentCount),
                levels.hasGlow ? 1 : 0,
                levels.intensity,
                solarFlareBlend
            )
        )
    }

    private var themeColor: SIMD3<Float> {
        guard configuration.appearance.isBusy else {
            return SIMD3(0x85 / 255.0, 0x8D / 255.0, 0x99 / 255.0)
        }
        return switch configuration.appearance.theme {
        case .sol: SIMD3(0xFF / 255.0, 0xC8 / 255.0, 0x3D / 255.0)
        case .terra: SIMD3(0x55 / 255.0, 0xD6 / 255.0, 0xFF / 255.0)
        case .luna: SIMD3(0xF4 / 255.0, 0xFA / 255.0, 0xFF / 255.0)
        case .other: SIMD3(0x28 / 255.0, 0xC8 / 255.0, 0x40 / 255.0)
        }
    }

    private func colorComponents(_ color: SIMD3<Float>) -> SIMD4<Float> {
        SIMD4(color.x, color.y, color.z, 1)
    }

    private func linearHDRBrightness(
        _ requestedBrightness: Float,
        blend: Float,
        policy: EDRDisplayPolicy
    ) -> Float {
        let hdrBrightness = policy.clampedHDRBrightness(requestedBrightness)
        return 1 + (hdrBrightness - 1) * blend
    }

    private func resolvedLevels(at seconds: TimeInterval) -> GlowLevels {
        let target = requestedLevels(at: seconds, motion: configuration.appearance.motion)
        guard let startedAt = motionTransitionStartedAt else { return target }

        let progress = Float(min(max(
            (seconds - startedAt) / Self.motionTransitionDuration,
            0
        ), 1))
        guard progress < 1 else {
            motionTransitionStartedAt = nil
            return target
        }

        let source = requestedLevels(at: seconds, motion: motionTransitionFrom)
        return interpolate(from: source, to: target, progress: progress)
    }

    private func requestedLevels(at seconds: TimeInterval, motion: GlowMotion) -> GlowLevels {
        guard configuration.appearance.isBusy else {
            return GlowLevels(
                coreBrightness: 1,
                peakBrightness: 1,
                ambientBrightness: 1,
                progress: 0,
                intensity: 1,
                motionCode: 0,
                hasGlow: false
            )
        }

        if configuration.reduceMotion {
            return GlowLevels(
                coreBrightness: 2.15,
                peakBrightness: 2.15,
                ambientBrightness: 1,
                progress: 0.37,
                intensity: 1,
                motionCode: motionCode,
                hasGlow: false
            )
        }

        switch motion {
        case .breathe:
            let period: TimeInterval = configuration.appearance.theme == .sol ? 5 : 2.5
            let wave = cosineWave(seconds: seconds, period: period)
            return GlowLevels(
                coreBrightness: interpolate(from: 1.15, to: 2.85, progress: wave),
                peakBrightness: interpolate(from: 1.25, to: 3.35, progress: wave),
                ambientBrightness: interpolate(from: 1.0, to: 1.35, progress: wave),
                progress: Float(seconds.truncatingRemainder(dividingBy: period) / period),
                intensity: 0.34 + 0.66 * wave,
                motionCode: 0,
                hasGlow: true
            )

        case .flow:
            return GlowLevels(
                coreBrightness: 1.35,
                peakBrightness: 3.8,
                ambientBrightness: 1.45,
                progress: Float(seconds.truncatingRemainder(dividingBy: 4) / 4),
                intensity: 1,
                motionCode: 1,
                hasGlow: true
            )

        case .solarFlare:
            return GlowLevels(
                // Twenty-four seconds halves the motion speed while the Metal
                // shader still uses integer frequencies and closes perfectly.
                coreBrightness: 1.15,
                peakBrightness: 5.6,
                ambientBrightness: 1.55,
                progress: Float(seconds.truncatingRemainder(dividingBy: 24) / 24),
                intensity: 1,
                motionCode: 2,
                hasGlow: true
            )
        }
    }

    private var motionCode: Float {
        switch configuration.appearance.motion {
        case .breathe: 0
        case .flow: 1
        case .solarFlare: 2
        }
    }

    private func cosineWave(seconds: TimeInterval, period: TimeInterval) -> Float {
        let progress = seconds.truncatingRemainder(dividingBy: period) / period
        return Float(0.5 - 0.5 * cos(progress * 2 * .pi))
    }

    private func interpolate(from: Float, to: Float, progress: Float) -> Float {
        from + (to - from) * progress
    }

    private func interpolate(from: GlowLevels, to: GlowLevels, progress: Float) -> GlowLevels {
        GlowLevels(
            coreBrightness: interpolate(from: from.coreBrightness, to: to.coreBrightness, progress: progress),
            peakBrightness: interpolate(from: from.peakBrightness, to: to.peakBrightness, progress: progress),
            ambientBrightness: interpolate(from: from.ambientBrightness, to: to.ambientBrightness, progress: progress),
            progress: interpolate(from: from.progress, to: to.progress, progress: progress),
            intensity: interpolate(from: from.intensity, to: to.intensity, progress: progress),
            motionCode: to.motionCode,
            hasGlow: from.hasGlow || to.hasGlow
        )
    }

    private func solarFlareBlend(at now: CFTimeInterval) -> Float {
        let target: Float = configuration.appearance.motion == .solarFlare ? 1 : 0
        guard let startedAt = motionTransitionStartedAt else { return target }

        let progress = Float(min(max(
            (now - startedAt) / Self.motionTransitionDuration,
            0
        ), 1))
        let source: Float = motionTransitionFrom == .solarFlare ? 1 : 0
        return source + (target - source) * progress
    }

    private func isMotionTransitioning(at now: CFTimeInterval) -> Bool {
        guard let startedAt = motionTransitionStartedAt else { return false }
        return now - startedAt < Self.motionTransitionDuration
    }

    private func liveGeometry(in view: MTKView) -> HDRGlowGeometry {
        let verticalGlowMargin = configuration.closesTop
            ? IslandDesign.glowOutset * 2
            : IslandDesign.glowOutset
        let liveSurfaceHeight = view.bounds.height - verticalGlowMargin
        let surfaceHeight = liveSurfaceHeight > 0
            ? liveSurfaceHeight
            : configuration.surfaceHeight
        let collapsedHeight = configuration.closesTop
            ? IslandDesign.collapsedHeight
            : IslandDesign.overlayCollapsedHeight
        let expandedHeight = configuration.closesTop
            ? IslandDesign.floatingExpandedHeight
            : IslandDesign.overlayExpandedHeight
        let expansionProgress = min(
            max((surfaceHeight - collapsedHeight) / max(expandedHeight - collapsedHeight, 1), 0),
            1
        )
        let bottomRadius = IslandDesign.floatingRadius
            + (IslandDesign.expandedRadius - IslandDesign.floatingRadius) * expansionProgress
        return HDRGlowGeometry(
            surfaceHeight: surfaceHeight,
            bottomRadius: bottomRadius
        )
    }

    private func makeSegments(scale: CGFloat, geometry: HDRGlowGeometry) -> [HDRGlowSegment] {
        let inset = IslandDesign.glowOutset * scale
        let topInset = configuration.closesTop ? inset : 0
        let width = IslandDesign.width * scale
        let height = geometry.surfaceHeight * scale
        let halfPixel = 0.5 * scale
        let x0 = inset + halfPixel
        let x1 = inset + width - halfPixel
        let y0 = topInset + halfPixel
        let y1 = topInset + height - halfPixel
        let drawablePathHeight = max(height - halfPixel * 2, 0)
        let radius = min(geometry.bottomRadius * scale, width / 2, drawablePathHeight / 2)

        var points: [SIMD2<Float>] = []
        func append(_ x: CGFloat, _ y: CGFloat) {
            points.append(SIMD2(Float(x), Float(y)))
        }
        func appendArc(centerX: CGFloat, centerY: CGFloat, radius: CGFloat, start: CGFloat, end: CGFloat) {
            let steps = 12
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let angle = start + (end - start) * t
                append(centerX + cos(angle) * radius, centerY + sin(angle) * radius)
            }
        }

        if configuration.closesTop {
            append(x0 + radius, y0)
            append(x1 - radius, y0)
            appendArc(centerX: x1 - radius, centerY: y0 + radius, radius: radius, start: -.pi / 2, end: 0)
            append(x1, y1 - radius)
            appendArc(centerX: x1 - radius, centerY: y1 - radius, radius: radius, start: 0, end: .pi / 2)
            append(x0 + radius, y1)
            appendArc(centerX: x0 + radius, centerY: y1 - radius, radius: radius, start: .pi / 2, end: .pi)
            append(x0, y0 + radius)
            appendArc(centerX: x0 + radius, centerY: y0 + radius, radius: radius, start: .pi, end: .pi * 1.5)
        } else {
            append(x1, y0)
            append(x1, y1 - radius)
            appendArc(centerX: x1 - radius, centerY: y1 - radius, radius: radius, start: 0, end: .pi / 2)
            append(x0 + radius, y1)
            appendArc(centerX: x0 + radius, centerY: y1 - radius, radius: radius, start: .pi / 2, end: .pi)
            append(x0, y0)
        }

        guard points.count > 1 else { return [] }
        var rawSegments: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            rawSegments.append((start, end, simd_length(end - start)))
        }
        let totalLength = rawSegments.reduce(Float.zero) { $0 + $1.2 }
        guard totalLength > 0 else { return [] }

        var traversed: Float = 0
        return rawSegments.map { start, end, length in
            defer { traversed += length }
            return HDRGlowSegment(
                endpoints: SIMD4(start.x, start.y, end.x, end.y),
                metrics: SIMD4(traversed / totalLength, length / totalLength, 0, 0)
            )
        }
    }
}

private struct GlowLevels {
    var coreBrightness: Float
    var peakBrightness: Float
    var ambientBrightness: Float
    var progress: Float
    var intensity: Float
    var motionCode: Float
    var hasGlow: Bool
}
