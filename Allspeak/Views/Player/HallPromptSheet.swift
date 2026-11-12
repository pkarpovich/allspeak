import SwiftUI

struct HallPromptSheet: View {
    let onSelect: (Hall) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Hall.manufaktura) { hall in
                Button(hall.name) {
                    onSelect(hall)
                    dismiss()
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Which hall are you in?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
