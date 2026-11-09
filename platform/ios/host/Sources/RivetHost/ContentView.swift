import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Racket + SwiftUI")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Count: \(model.count)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    Button("Increment in Racket") {
                        model.increment()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.ready)

                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(model.ready ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(RivetGeneratedConfig.displayName)
        }
    }
}
