import SwiftUI

struct HallPromptSheet: View {
    let onSelect: (Hall) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Which hall are you in?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Hall.manufaktura) { hall in
                        Button {
                            onSelect(hall)
                            dismiss()
                        } label: {
                            Text(hall.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Tokens.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Tokens.surface, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .preferredColorScheme(.dark)
    }
}
