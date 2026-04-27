import SwiftUI

enum FirstRunStep: Int, CaseIterable {
    case introduction
    case calibration
    case loginItems

    var next: FirstRunStep? {
        FirstRunStep(rawValue: rawValue + 1)
    }

    var previous: FirstRunStep? {
        FirstRunStep(rawValue: rawValue - 1)
    }
}
