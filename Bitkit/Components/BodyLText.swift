import SwiftUI

/// Large body text component for Paykit views
struct BodyLText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold))
    }
}
