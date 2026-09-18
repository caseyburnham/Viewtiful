import Foundation

/// Converts a wheel notch or a complete trackpad gesture into one page action.
struct ScrollPageNavigation {
    private var accumulatedDelta = 0.0
    private var didTurnInGesture = false
    private var lastEvent = -Double.infinity
    private var lastWheelTurn = -Double.infinity

    mutating func action(delta: Double, precise: Bool, began: Bool, ended: Bool,
                         momentum: Bool, timestamp: Double) -> ViewtifulAction? {
        guard !momentum else { return nil }
        if began || timestamp - lastEvent > 0.25 {
            accumulatedDelta = 0
            didTurnInGesture = false
        }
        lastEvent = timestamp
        guard !ended, delta != 0 else { return nil }
        if precise {
            guard !didTurnInGesture else { return nil }
            accumulatedDelta += delta
            guard abs(accumulatedDelta) >= 24 else { return nil }
            didTurnInGesture = true
            return accumulatedDelta < 0 ? .nextPage : .previousPage
        }
        guard timestamp - lastWheelTurn >= 0.18 else { return nil }
        lastWheelTurn = timestamp
        return delta < 0 ? .nextPage : .previousPage
    }
}
