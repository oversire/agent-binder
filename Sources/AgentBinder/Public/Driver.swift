import Foundation

/// Starts sessions for one vendor protocol.
///
/// The runtime has a built-in driver for each CLI harness. A consumer can register its own driver
/// with ``Runtime/setDriver(_:for:)``. Optional capabilities are the protocols ``ModelListing``,
/// ``LimitsReading`` and ``SelfDetecting``.
public protocol Driver: Sendable {
    /// The name of the driver, for logs.
    var name: String { get }

    /// Starts a new session. It returns after the protocol handshake.
    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session

    /// Opens a known session again. It throws ``AgentBinderError/resumeUnsupported`` when the vendor
    /// does not know the session, or the protocol has no resume.
    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session
}

/// A driver that lists the models of its harness without a live session.
public protocol ModelListing: Driver {
    /// Lists the models. The runtime caches the result.
    func models(_ q: ModelQuery, runtime: RuntimeContext) async throws -> [ModelInfo]
}

/// A driver that reads the plan limits of the account.
public protocol LimitsReading: Driver {
    /// Reads the limits. The runtime does not cache the result.
    func readLimits(_ q: ModelQuery, runtime: RuntimeContext) async throws -> Limits
}

/// A driver that answers ``Runtime/detect(_:)`` itself, for example an in-process harness with no binary.
public protocol SelfDetecting: Driver {
    /// Reports the state of the harness. The runtime fills the features and ``Detection/ready``.
    func detect(runtime: RuntimeContext) async throws -> Detection
}
