import Foundation

extension SessionContinuityConfiguration {
    /// The same schedule with every session-age duration divided by
    /// `factor`: the 120-minute limit, the renewal at 110 and its 118-minute
    /// deadline, the token refresh lead, the renewal retry and the idle
    /// limit. A replay that plays two hours of audio in twelve minutes
    /// (`factor` 10) renews its session at the same point of the
    /// conversation as a real session would (#76).
    ///
    /// `resumeConfirmationTimeout` is left alone: it waits for the server,
    /// whose speed doesn't change.
    ///
    /// - Precondition: `factor > 0`.
    public func scaled(by factor: Double) -> SessionContinuityConfiguration {
        precondition(factor > 0 && factor.isFinite, "The scale factor must be positive")
        func scale(_ duration: Duration) -> Duration { duration / factor }
        var scaled = self
        scaled.maximumSessionDuration = scale(maximumSessionDuration)
        scaled.rolloverAfter = rolloverAfter.map(scale)
        scaled.rolloverDeadline = scale(rolloverDeadline)
        scaled.tokenRefreshLead = scale(tokenRefreshLead)
        scaled.rolloverRetryInterval = scale(rolloverRetryInterval)
        scaled.resumptionIdleLimit = scale(resumptionIdleLimit)
        return scaled
    }
}
