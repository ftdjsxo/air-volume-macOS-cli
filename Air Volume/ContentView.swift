//
//  ContentView.swift
//  Air Volume
//
//  Created by Francesco on 28/09/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var service = AirVolumeService()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stato")
                    .font(.headline)
                Text(service.state.description)
                    .font(.system(.body, design: .rounded))
                if let target = service.currentTarget {
                    Text("Device: \(target.name ?? "\(target.ip):\(target.wsPort)")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Device non disponibile")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let volume = service.lastVolumePercent {
                    Text("Volume ultimo: \(volume)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button {
                    service.copyLogsToPasteboard()
                } label: {
                    Label("Copia", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(service.logs.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 220)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 480)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }
}

#Preview {
    ContentView()
}
