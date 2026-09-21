import Metal

enum MetalDeviceProvider {
    static let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device unavailable")
        }
        return device
    }()
}
