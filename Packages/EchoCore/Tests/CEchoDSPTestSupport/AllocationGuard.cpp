#include "AllocationGuard.hpp"

#include <cstdlib>
#include <new>

namespace {

thread_local bool isGuarding = false;
thread_local int allocationCount = 0;

void* allocate(std::size_t size) noexcept {
    if (isGuarding) { ++allocationCount; }
    return std::malloc(size == 0 ? 1 : size);
}

void* allocateAligned(std::size_t size, std::align_val_t alignment) noexcept {
    if (isGuarding) { ++allocationCount; }
    void* pointer = nullptr;
    const auto bytes = static_cast<std::size_t>(alignment);
    return posix_memalign(&pointer, bytes < sizeof(void*) ? sizeof(void*) : bytes, size == 0 ? 1 : size) == 0 ? pointer : nullptr;
}

void* allocateOrAbort(std::size_t size) {
    if (void* pointer = allocate(size)) { return pointer; }
    std::abort();
}

void* allocateAlignedOrAbort(std::size_t size, std::align_val_t alignment) {
    if (void* pointer = allocateAligned(size, alignment)) { return pointer; }
    std::abort();
}

/// Keeps the test allocation observable so the compiler can't elide it.
int* volatile allocationSink = nullptr;

} // namespace

namespace echo::test {

void beginAllocationGuard() noexcept {
    allocationCount = 0;
    isGuarding = true;
}

int endAllocationGuard() noexcept {
    isGuarding = false;
    return allocationCount;
}

void allocateOnceForTesting() noexcept {
    allocationSink = new int(1);
    delete allocationSink;
    allocationSink = nullptr;
}

} // namespace echo::test

void* operator new(std::size_t size) { return allocateOrAbort(size); }
void* operator new[](std::size_t size) { return allocateOrAbort(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept { return allocate(size); }
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept { return allocate(size); }
void* operator new(std::size_t size, std::align_val_t alignment) { return allocateAlignedOrAbort(size, alignment); }
void* operator new[](std::size_t size, std::align_val_t alignment) { return allocateAlignedOrAbort(size, alignment); }

void operator delete(void* pointer) noexcept { std::free(pointer); }
void operator delete[](void* pointer) noexcept { std::free(pointer); }
void operator delete(void* pointer, std::size_t) noexcept { std::free(pointer); }
void operator delete[](void* pointer, std::size_t) noexcept { std::free(pointer); }
void operator delete(void* pointer, std::align_val_t) noexcept { std::free(pointer); }
void operator delete[](void* pointer, std::align_val_t) noexcept { std::free(pointer); }
void operator delete(void* pointer, std::size_t, std::align_val_t) noexcept { std::free(pointer); }
void operator delete[](void* pointer, std::size_t, std::align_val_t) noexcept { std::free(pointer); }
