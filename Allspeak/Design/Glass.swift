import SwiftUI

struct ChromeGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if #available(iOS 26, *) {
                    shape.fill(Tokens.Glyph.chrome).glassEffect(.regular, in: shape)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Tokens.Glyph.chrome))
                }
            }
            .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 0.5))
            .clipShape(shape)
    }
}

struct PlateGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if #available(iOS 26, *) {
                    shape.fill(Tokens.Glyph.plate).glassEffect(.regular, in: shape)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Tokens.Glyph.plate))
                }
            }
            .overlay(shape.strokeBorder(Tokens.hairlineSoft, lineWidth: 0.5))
            .clipShape(shape)
    }
}

extension View {
    func chromeGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(ChromeGlassModifier(cornerRadius: cornerRadius))
    }

    func plateGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(PlateGlassModifier(cornerRadius: cornerRadius))
    }
}
