#pragma once

// Test-only: counts C++ heap allocations (`operator new`) made on the calling thread, so tests can prove the DSP
// kernels never allocate while processing (CLAUDE.md: no allocation on the render thread). Linking this target
// replaces the global `operator new`/`operator delete` in the test binary.

namespace echo::test {

/// Starts counting allocations on this thread from zero.
void beginAllocationGuard() noexcept;
/// Stops counting and returns the number of allocations since `beginAllocationGuard()`.
int endAllocationGuard() noexcept;
/// Allocates and frees once, to prove the guard sees allocations.
void allocateOnceForTesting() noexcept;

} // namespace echo::test
