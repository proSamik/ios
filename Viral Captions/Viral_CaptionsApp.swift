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
                #if os(macOS)
                .frame(minWidth: 1080, minHeight: 720)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unified)
        #endif
    }
}
