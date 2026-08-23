//
//  LiminalGeneratorApp.swift
//  LiminalGenerator
//
//  App entry point: shows the in-app splash (~2s) then transitions to
//  MainView, per SPEC.md "Screens & behavior".
//

import SwiftUI

@main
struct LiminalGeneratorApp: App {
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainView()

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showSplash = false
                    }
                }
            }
        }
    }
}
