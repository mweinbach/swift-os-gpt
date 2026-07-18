@main
struct VirtIOFeatureNegotiationTests {
    static func main() {
        selectsRequiredAndOfferedOptionalFeatures()
        rejectsMissingRequiredFeatures()
        neverAcceptsUnavailableOptionalFeatures()
        print("VirtIO feature negotiation: 3 groups passed")
    }

    private static func selectsRequiredAndOfferedOptionalFeatures() {
        let virgl: UInt64 = 1 << 0
        let resourceBlob: UInt64 = 1 << 3
        let offered = VirtIOTransportFeature.version1 | virgl | resourceBlob
        guard let selection = VirtIOFeatureSelection.select(
            offered: offered,
            required: VirtIOTransportFeature.version1,
            optional: virgl
        ) else {
            fail("valid feature selection was rejected")
        }
        require(selection.offered == offered, "offered mask was not retained")
        require(
            selection.accepted == VirtIOTransportFeature.version1 | virgl,
            "required and requested optional features were not selected"
        )
    }

    private static func rejectsMissingRequiredFeatures() {
        require(
            VirtIOFeatureSelection.select(
                offered: 1,
                required: VirtIOTransportFeature.version1,
                optional: 1
            ) == nil,
            "selection accepted a device without VIRTIO_F_VERSION_1"
        )
    }

    private static func neverAcceptsUnavailableOptionalFeatures() {
        let virgl: UInt64 = 1 << 0
        let unavailable: UInt64 = 1 << 4
        guard let selection = VirtIOFeatureSelection.select(
            offered: VirtIOTransportFeature.version1 | virgl,
            required: VirtIOTransportFeature.version1,
            optional: virgl | unavailable
        ) else {
            fail("valid feature selection was rejected")
        }
        require(
            selection.accepted & unavailable == 0,
            "selection acknowledged an unavailable optional feature"
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("\(message)")
    }
}
