//
//  ContentView.swift
//  progress
//
//  Created by Simon Riepl on 19.02.26.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var resumedImport: PhotoImportResumeRequest?

    var body: some View {
        PhotoGridView()
            .task {
                resumedImport = PhotoImportSettingsRecovery.consume()
                await TimelineSelectionStore.shared.start(in: viewContext)
                TimelineDeletionService.shared.start(in: viewContext)
            }
            .sheet(item: $resumedImport) { request in
                NavigationStack {
                    PhotoImportSettingsView(timelineID: request.timelineID, resuming: request.method)
                }
            }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
