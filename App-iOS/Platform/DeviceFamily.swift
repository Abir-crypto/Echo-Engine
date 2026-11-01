import SwiftUI
import UIKit

/// iPhone or iPad, for wording such as "free up space on your iPad". Read from `UIDevice` once at the app root and
/// passed down through the environment, so views don't reach for the singleton (SPEC § 4.1).
enum DeviceFamily: Sendable {
    case phone, pad

    @MainActor static var current: DeviceFamily {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}

extension EnvironmentValues {
    @Entry var deviceFamily: DeviceFamily = .phone
}
