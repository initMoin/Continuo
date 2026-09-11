//
//  ContinuoApp.swift
//  Continuo
//
//  Created by Moinuddin Ahmad on 8/14/26.
//

import SwiftUI

@main
struct ContinuoApp: App {
#if os(macOS)
    init() {
        ContinuoFontRegistrar.registerBundledFonts()
    }
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
#endif
    }
}
