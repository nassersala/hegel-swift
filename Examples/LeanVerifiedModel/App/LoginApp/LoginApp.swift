import LoginUI
import SwiftUI

/// The screen on the simulator. Toggle `resendResetsAttempts` to run the
/// buggy variant the property test catches.
@main
struct LoginApp: App {
    @State private var model = LoginViewModel(resendResetsAttempts: false)

    var body: some Scene {
        WindowGroup {
            LoginView(model: model)
        }
    }
}
