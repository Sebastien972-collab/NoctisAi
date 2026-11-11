import Foundation

public struct InterfaceLimits: Sendable, Equatable {
    public var maximumEncodedBytes = 256 * 1_024
    public var maximumNodes = 128
    public var maximumDepth = 8
    public var maximumChildrenPerNode = 32
    public var maximumActionsPerNode = 8
    public var maximumStringBytes = 16 * 1_024

    public init() {}
}
