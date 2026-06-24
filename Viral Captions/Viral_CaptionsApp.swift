//
//  Viral_CaptionsApp.swift
//  Viral Captions
//
//  Created by Samik Choudhury on 25/06/26.
//

import SwiftUI

@main
struct Viral_CaptionsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif
    }
}
