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

    var body: some View {
        PhotoGridView()
            .task {
                await TimelineSelectionStore.shared.start(in: viewContext)
                TimelineDeletionService.shared.start(in: viewContext)
            }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
