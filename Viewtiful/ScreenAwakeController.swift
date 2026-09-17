import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#endif

@MainActor
final class ScreenAwakeController {
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    func update(shouldStayAwake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        #elseif os(macOS)
        if shouldStayAwake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Displaying an active show document"
            )
        } else if !shouldStayAwake, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }

    deinit {
        #if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        #endif
    }
}
