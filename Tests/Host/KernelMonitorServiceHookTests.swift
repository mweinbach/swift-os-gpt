private nonisolated(unsafe) var serviceCallCount = 0

@_cdecl("swiftos_kernel_monitor_service_hook_test_spy")
func kernelMonitorServiceHookTestSpy() {
    serviceCallCount += 1
}

@main
struct KernelMonitorServiceHookTests {
    static func main() {
        serviceKernelMonitorWorkOnce(nil)
        expect(serviceCallCount == 0, "nil service hook must be inert")

        let hook: KernelMonitorServiceHook =
            kernelMonitorServiceHookTestSpy
        serviceKernelMonitorWorkOnce(hook)
        expect(serviceCallCount == 1, "service hook runs exactly once")

        serviceKernelMonitorWorkOnce(hook)
        expect(serviceCallCount == 2, "each iteration runs one service step")

        print("kernel monitor service hook host tests: 3 passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("kernel monitor service hook test failed: \(message)")
        }
    }
}
