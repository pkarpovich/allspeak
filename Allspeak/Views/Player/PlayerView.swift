import CoreData
import SwiftUI

struct PlayerView: View {
    let sessionID: NSManagedObjectID

    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 8) {
                Text(resolvedName)
                    .font(Tokens.Font.title)
                    .foregroundStyle(Tokens.text)
                Text("Player coming in Task 10")
                    .font(Tokens.Font.mono)
                    .foregroundStyle(Tokens.text3)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var resolvedName: String {
        guard let object = try? viewContext.existingObject(with: sessionID) else { return "" }
        return (object.value(forKey: "name") as? String) ?? ""
    }
}
