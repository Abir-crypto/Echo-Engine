import CEchoDSP
import Testing

struct CxxInteropTests {
    @Test func cxxFunctionIsCallableFromSwift() {
        #expect(abs(echo.dsp.dbToLinear(0) - 1) < 1e-6)
        #expect(abs(echo.dsp.dbToLinear(-6.0206) - 0.5) < 1e-4)
    }
}
