import SwiftUI
@testable import OvercrossCore

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        MainLibraryView()
            .preferredColorScheme(.dark)
            .tint(.purple)
            .frame(minWidth: 900, minHeight: 600)
    }
}
