import CEchoDSP
import CEchoDSPTestSupport
import Foundation
import Testing

/// Kernel output on a fixed input must match the recorded reference (`Resources/TestAudio/Golden/<kernel>.f32`, raw
/// little-endian Float32 mono). After an intended DSP change, re-record with `ECHO_UPDATE_GOLDEN=1 swift test`.
struct KernelGoldenTests {
    /// Far below audible, far above float rounding differences between builds.
    static let toleranceDB: Float = -80

    @Test(arguments: KernelScenario.all)
    func matchesTheGoldenFile(_ scenario: KernelScenario) throws {
        let buffers = ChannelBuffers([TestSignal.speechLike()])
        scenario.run(buffers)
        let output = buffers.output[0]

        if ProcessInfo.processInfo.environment["ECHO_UPDATE_GOLDEN"] == "1" {
            try Self.write(output, to: Self.sourceURL(scenario.name))
            return
        }
        let url = try #require(
            Bundle.module.url(forResource: scenario.name, withExtension: "f32", subdirectory: "Resources/TestAudio/Golden"),
            "No golden file for \(scenario.name); record it with ECHO_UPDATE_GOLDEN=1"
        )
        let reference = try Self.read(url)
        try #require(reference.count == output.count)
        let difference = zip(output, reference).map { $0 - $1 }
        #expect(TestSignal.rmsDB(difference) < Self.toleranceDB)
    }

    @Test(arguments: KernelScenario.all)
    func neverAllocates(_ scenario: KernelScenario) {
        let buffers = ChannelBuffers([TestSignal.speechLike(), TestSignal.speechLike()])

        echo.test.beginAllocationGuard()
        scenario.run(buffers)
        let allocations = echo.test.endAllocationGuard()

        #expect(allocations == 0)
    }

    @Test func theAllocationGuardSeesAllocations() {
        echo.test.beginAllocationGuard()
        echo.test.allocateOnceForTesting()
        #expect(echo.test.endAllocationGuard() == 1)
    }

    private static func sourceURL(_ name: String, file: String = #filePath) -> URL {
        URL(filePath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/TestAudio/Golden/\(name).f32")
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let data = samples.map(\.bitPattern.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return stride(from: 0, to: data.count - 3, by: 4).map { offset in
            let bits = data[data.startIndex + offset..<data.startIndex + offset + 4]
                .enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
    }
}
