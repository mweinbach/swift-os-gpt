@main
struct PollingNetworkServiceTests {
    static func main() {
        ownsLinkAndDrivesBoundedDHCPWork()
        rejectsUnsafeScratchLayouts()
        print("Polling network service: 2 groups passed")
    }

    private static func ownsLinkAndDrivesBoundedDHCPWork() {
        var receive = [UInt8](repeating: 0, count: 2_048)
        var transmit = [UInt8](repeating: 0, count: 2_048)
        receive.withUnsafeMutableBytes { receiveBytes in
            transmit.withUnsafeMutableBytes { transmitBytes in
                guard let receiveBase = receiveBytes.baseAddress,
                      let transmitBase = transmitBytes.baseAddress,
                      var service = PollingNetworkService(
                          link: TestLink(),
                          receiveScratchAddress: UInt64(
                              UInt(bitPattern: receiveBase)
                          ),
                          transmitScratchAddress: UInt64(
                              UInt(bitPattern: transmitBase)
                          ),
                          scratchByteCount: 2_048,
                          dhcpTransactionIdentifier: 0x1234_5678,
                          timing: IPv4PollingStackTiming(
                              arpEntryLifetimeTicks: 1_000,
                              arpProbeIntervalTicks: 10,
                              dhcpRetryPolicy: DHCPv4RetryPolicy(
                                  initialRetryTicks: 10,
                                  maximumRetryTicks: 40
                              )
                          ),
                          startAtTicks: 100
                      )
                else { fail("valid polling service was rejected") }

                guard case .dhcpDiscoverSent = service.poll(nowTicks: 100)
                else { fail("service did not drive DHCP deadline") }
                expect(
                    service.link.transmittedFrame.count
                        == EthernetIIProtocol.headerByteCount
                            + IPv4Protocol.headerByteCount
                            + UDPProtocol.headerByteCount
                            + 300,
                    "service transmitted an unexpected DHCP frame size"
                )
                expect(
                    service.networkConfiguration == nil,
                    "service configured an address without a lease"
                )
            }
        }
    }

    private static func rejectsUnsafeScratchLayouts() {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        bytes.withUnsafeMutableBytes { storage in
            guard let base = storage.baseAddress else {
                fail("test storage has no base")
            }
            let address = UInt64(UInt(bitPattern: base))
            let timing = IPv4PollingStackTiming(
                arpEntryLifetimeTicks: 1,
                arpProbeIntervalTicks: 1,
                dhcpRetryPolicy: DHCPv4RetryPolicy(
                    initialRetryTicks: 1,
                    maximumRetryTicks: 1
                )
            )
            expect(
                PollingNetworkService(
                    link: TestLink(),
                    receiveScratchAddress: address,
                    transmitScratchAddress: address + 1_024,
                    scratchByteCount: 1_024,
                    dhcpTransactionIdentifier: 1,
                    timing: timing,
                    startAtTicks: 0
                ) == nil,
                "undersized and overlapping scratch was accepted"
            )
            expect(
                PollingNetworkService(
                    link: TestLink(),
                    receiveScratchAddress: address,
                    transmitScratchAddress: address + 2_048,
                    scratchByteCount: 2_048,
                    dhcpTransactionIdentifier: 1,
                    timing: timing,
                    startAtTicks: 0
                ) != nil,
                "disjoint scratch was rejected"
            )
        }
    }

    private struct TestLink: NetworkLink {
        let macAddress = MACAddress(0x02, 0, 0, 0, 0, 1)
        let mtu: UInt16 = 1_500
        var linkState: NetworkLinkState { .up }
        private(set) var transmittedFrame: [UInt8] = []

        mutating func pollReceive(
            into output: UnsafeMutableRawBufferPointer
        ) -> NetworkLinkReceiveResult {
            .noPacket
        }

        mutating func transmit(
            _ frame: UnsafeRawBufferPointer
        ) -> NetworkLinkTransmitResult {
            transmittedFrame = Array(frame)
            return .sent
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        print("FAIL:", message)
        fatalError()
    }
}
