//
//  Viral_CaptionsApp.swift
//  Viral Captions
//
//  Created by Samik Choudhury on 25/06/26.
//

import SwiftUI
import SwiftData

@main
struct Viral_CaptionsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: Item.self)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif
    }
}
