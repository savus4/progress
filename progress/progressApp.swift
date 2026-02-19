//
//  progressApp.swift
//  progress
//
//  Created by Simon Riepl on 19.02.26.
//

import SwiftUI
import CoreData

@main
struct progressApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
