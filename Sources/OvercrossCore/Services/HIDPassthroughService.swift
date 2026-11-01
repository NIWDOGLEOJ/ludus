import Foundation

public struct ControllerDeviceIdentity: Sendable, Equatable {
    public let vendorID: Int
    public let productID: Int
    public let name: String
    public let isSonyDualSense: Bool
    public let isSonyDualShock: Bool
    public let isXbox: Bool

    public init(
        vendorID: Int,
        productID: Int,
        name: String,
        isSonyDualSense: Bool = false,
        isSonyDualShock: Bool = false,
        isXbox: Bool = false
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.isSonyDualSense = isSonyDualSense
        self.isSonyDualShock = isSonyDualShock
        self.isXbox = isXbox
    }
}

public struct HIDPassthroughService: Sendable {
    public init() {}

    public static let supportedControllers: [ControllerDeviceIdentity] = [
        // Sony DualSense (PS5)
        ControllerDeviceIdentity(vendorID: 0x054c, productID: 0x0ce6, name: "Sony DualSense Wireless Controller", isSonyDualSense: true, isSonyDualShock: false, isXbox: false),
        // Sony DualSense Edge
        ControllerDeviceIdentity(vendorID: 0x054c, productID: 0x0df2, name: "Sony DualSense Edge Wireless Controller", isSonyDualSense: true, isSonyDualShock: false, isXbox: false),
        // Sony DualShock 4
        ControllerDeviceIdentity(vendorID: 0x054c, productID: 0x09cc, name: "Sony DualShock 4 Wireless Controller", isSonyDualSense: false, isSonyDualShock: true, isXbox: false),
        // Microsoft Xbox 360 / One
        ControllerDeviceIdentity(vendorID: 0x045e, productID: 0x028e, name: "Microsoft Xbox Controller", isSonyDualSense: false, isSonyDualShock: false, isXbox: true)
    ]

    public static func isDualSense(vendorID: Int, productID: Int) -> Bool {
        return (vendorID == 0x054c && (productID == 0x0ce6 || productID == 0x0df2))
    }

    public static func isPlayStationController(vendorID: Int, productID: Int) -> Bool {
        return vendorID == 0x054c
    }

    /// Generates DirectInput and XInput registry configuration for optimal controller response, zero deadzone, and high-precision rumble.
    public static func controllerRegistrySettings() -> [String: [String: String]] {
        return [
            "Software\\\\Wine\\\\DirectInput": [
                "\"DefaultDeadZone\"": "\"0\"",
                "\"MouseWarpOverride\"": "\"force\""
            ],
            "Software\\\\Wine\\\\XInput": [
                "\"EnableXInput\"": "\"y\""
            ]
        ]
    }
}
