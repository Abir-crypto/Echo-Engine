import CEchoDSP
import CEchoDSPTestSupport
import Foundation
import Testing

/// Kernel output on a fixed input must match the recorded reference (`GoldenFile`), and never allocate.
struct KernelGoldenTests {
    @Test(arguments: KernelScenario.all)
    func matchesTheGoldenFile(_ scenario: KernelScenario) throws {
        let buffers = ChannelBuffers([TestSignal.speechLike()])
        scenario.run(buffers) { $0() }
        if let difference = try GoldenFile.differenceDB(of: buffers.output[0], name: scenario.name) {
            #expect(difference < GoldenFile.toleranceDB)
        }
    }

    @Test(arguments: KernelScenario.all)
    func neverAllocates(_ scenario: KernelScenario) {
        let buffers = ChannelBuffers([TestSignal.speechLike(), TestSignal.speechLike()])
        var allocations: Int32 = -1

        scenario.run(buffers) { render in
            echo.test.beginAllocationGuard()
            render()
            allocations = echo.test.endAllocationGuard()
        }

        #expect(allocations == 0)
    }

    @Test func theAllocationGuardSeesAllocations() {
        echo.test.beginAllocationGuard()
        echo.test.allocateOnceForTesting()
        #expect(echo.test.endAllocationGuard() == 1)
    }
}
