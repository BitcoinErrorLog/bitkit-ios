import SwiftUI

/// Large body text component for Paykit views
struct BodyLText: View {
    let text: String
    var textColor: Color = .textPrimary

    init(_ text: String, textColor: Color = .textPrimary) {
        self.text = text
        self.textColor = textColor
    }

    var body: some View {
        Text(text)
            .font(Fonts.semiBold(size: 24))
            .foregroundColor(textColor)
            .kerning(0.4)
    }
}
