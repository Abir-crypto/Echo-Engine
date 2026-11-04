import AVFoundation
import CEchoDSP

/// Captures the recording input (SPEC § 13.3, § 13.4): one input bus with every channel of the input device, one output
/// bus with the processed mixdown for monitoring. The render block is `CaptureCore`'s own Objective-C++ block: it meters
/// every input channel and, while capturing, queues the selected channels and the processed mixdown for the take
/// writer. Rendering never touches Swift (SPEC § 4.5).
public final class RecordingCaptureAudioUnit: AUAudioUnit {
    public static let componentDescription = AudioComponentDescription.echoEffect(subType: "ecRC")

    /// The render side's state, shared with the take writer.
    public let core = CaptureCore()
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private var layout: Layout?

    private struct Layout {
        let sampleRate: Double
        let inputChannelCount: Int
        let channels: [Int]
        let mixdownChannelCount: Int
        let ringFrames: Int
    }

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        inputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = AUAudioChannelCount(CaptureCore.maximumInputChannels)
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096

        // Live processing (SPEC § 13.4): changes reach the render thread through the parameter tree only.
        let suppression = AUParameterTree.createParameter(
            withIdentifier: "suppression", name: "suppression", address: EECaptureParameter.suppression.rawValue,
            min: 0, max: 2, unit: .indexed, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: ["off", "standard", "high"], dependentParameters: nil
        )
        let tree = AUParameterTree.createTree(withChildren: [suppression])
        tree.implementorValueObserver = { [core] parameter, value in core.setParameter(parameter.address, value) }
        tree.implementorValueProvider = { [core] parameter in core.parameter(parameter.address) }
        parameterTree = tree
    }

    /// Sets a live processing parameter (`EECaptureParameter`) through the tree; it ramps where it applies.
    public func setParameter(_ address: EECaptureParameter, _ value: AUValue) {
        parameterTree?.parameter(withAddress: address.rawValue)?.value = value
    }

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    /// Lays out metering, the mixdown and the ring before the engine starts; never while it renders. `channels` are input
    /// channel indices in take order; a mixdown of 1 channel sums them, of 2 takes them as left and right. Throws when
    /// the layout is invalid, or differs from the open take's.
    public func configure(sampleRate: Double, inputChannelCount: Int, channels: [Int], mixdownChannelCount: Int, ringFrames: Int) throws {
        let layout = Layout(
            sampleRate: sampleRate, inputChannelCount: inputChannelCount, channels: channels,
            mixdownChannelCount: mixdownChannelCount, ringFrames: ringFrames
        )
        try apply(layout, maximumFrames: Int(maximumFramesToRender))
        self.layout = layout
    }

    private func apply(_ layout: Layout, maximumFrames: Int) throws {
        guard core.configure(
            sampleRate: layout.sampleRate, inputChannelCount: layout.inputChannelCount, channels: layout.channels,
            mixdownChannelCount: layout.mixdownChannelCount, maximumFrames: maximumFrames, ringFrames: layout.ringFrames
        ) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidPropertyValue))
        }
    }

    public override func allocateRenderResources() throws {
        let input = inputBus.format
        let output = outputBus.format
        guard let layout, input.commonFormat == .pcmFormatFloat32, !input.isInterleaved,
              output.commonFormat == .pcmFormatFloat32, !output.isInterleaved,
              input.sampleRate == layout.sampleRate, output.sampleRate == layout.sampleRate,
              Int(input.channelCount) == layout.inputChannelCount, Int(output.channelCount) == layout.mixdownChannelCount else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        if Int(maximumFramesToRender) > core.maximumFrames {
            try apply(layout, maximumFrames: Int(maximumFramesToRender))
        }
        try super.allocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        EECaptureCoreRenderBlock(core.pointer)
    }
}

/// Owns an `EECaptureCore`: meters, mixdown and the lock-free ring between the render thread and the take writer (SPEC
/// § 13.3). Shared by `RecordingCaptureAudioUnit` and the writer, so it lives as long as either needs it.
///
/// Thread safety (hence `@unchecked Sendable`): capturing, take state, counters and peaks are atomics usable from any
/// thread; `read` and `discard` belong to one writer at a time; `configure` runs only while nothing renders or reads.
public final class CaptureCore: @unchecked Sendable {
    /// Most channels of one input device that can be metered and recorded.
    public static let maximumInputChannels = Int(EE_CAPTURE_MAX_INPUT_CHANNELS)

    let pointer: OpaquePointer

    public init() {
        pointer = EECaptureCoreCreate()
    }

    deinit {
        EECaptureCoreDestroy(pointer)
    }

    /// See `RecordingCaptureAudioUnit.configure`. Returns false when the layout is invalid or refused.
    public func configure(
        sampleRate: Double, inputChannelCount: Int, channels: [Int], mixdownChannelCount: Int, maximumFrames: Int, ringFrames: Int
    ) -> Bool {
        let selected = channels.map { Int32(clamping: $0) }
        return selected.withUnsafeBufferPointer { selected in
            EECaptureCoreConfigure(
                pointer, sampleRate, Int32(clamping: inputChannelCount), selected.baseAddress, Int32(clamping: selected.count),
                Int32(clamping: mixdownChannelCount), Int32(clamping: maximumFrames), Int32(clamping: ringFrames)
            )
        }
    }

    public var isConfigured: Bool { EECaptureCoreIsConfigured(pointer) }
    public var sampleRate: Double { EECaptureCoreSampleRate(pointer) }
    public var inputChannelCount: Int { Int(EECaptureCoreInputChannelCount(pointer)) }
    public var mixdownChannelCount: Int { Int(EECaptureCoreMixdownChannelCount(pointer)) }
    public var maximumFrames: Int { Int(EECaptureCoreMaximumFrames(pointer)) }
    /// Planes per frame: the selected raw channels in take order, then the processed mixdown's channels.
    public var planeCount: Int { Int(EECaptureCorePlaneCount(pointer)) }
    /// How far the processed planes are behind the raw ones; the writer removes it.
    public var processedLatencyFrames: Int { Int(EECaptureCoreProcessedLatencyFrames(pointer)) }
    /// High (RNNoise) runs at 44.1 kHz or more; below, it acts as Standard.
    public var supportsHigh: Bool { EECaptureCoreSupportsHigh(pointer) }

    func setParameter(_ address: AUParameterAddress, _ value: AUValue) {
        EECaptureCoreSetParameter(pointer, address, value)
    }

    func parameter(_ address: AUParameterAddress) -> AUValue {
        EECaptureCoreParameter(pointer, address)
    }

    /// Tests without an Audio Unit: sets a parameter directly.
    public func setParameterForTesting(_ address: EECaptureParameter, _ value: Float) {
        EECaptureCoreSetParameter(pointer, address.rawValue, value)
    }

    /// While a take is open its layout can't change.
    public func setTakeOpen(_ isOpen: Bool) {
        EECaptureCoreSetTakeOpen(pointer, isOpen)
    }

    /// While true, rendered audio is queued for the writer; meters always run.
    public func setCapturing(_ isCapturing: Bool) {
        EECaptureCoreSetCapturing(pointer, isCapturing)
    }

    /// Render cycles finished; once it grew by 2 after `setCapturing(false)`, nothing more is queued.
    public var renderCycles: UInt64 { EECaptureCoreRenderCycles(pointer) }
    /// Frames captured so far (at the input's rate), including dropped ones.
    public var capturedFrames: Int64 { EECaptureCoreCapturedFrames(pointer) }
    /// Frames lost because the writer fell behind; `read` returns silence in their place.
    public var droppedFrames: Int64 { EECaptureCoreDroppedFrames(pointer) }

    /// Copies up to `maximumFrames` queued frames into `planes` (`planeCount` pointers). Returns the frames copied.
    public func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>?>, maximumFrames: Int) -> Int {
        Int(EECaptureCoreRead(pointer, planes, Int32(clamping: maximumFrames)))
    }

    /// Forgets everything queued; only while not capturing.
    public func discard() {
        EECaptureCoreDiscard(pointer)
    }

    /// The highest |sample| of each input channel since the previous call (1 = full scale).
    public func takePeaks() -> [Float] {
        let count = inputChannelCount
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = Int(EECaptureCoreTakePeaks(pointer, buffer.baseAddress, Int32(count)))
        }
    }

    /// Offline (tests): render cycles over `input` (one pointer per input channel), the monitor output into `output`.
    public func process(
        input: UnsafePointer<UnsafePointer<Float>?>, output: UnsafePointer<UnsafeMutablePointer<Float>?>?, frameCount: Int
    ) {
        EECaptureCoreProcess(pointer, input, output, Int32(clamping: frameCount))
    }
}
