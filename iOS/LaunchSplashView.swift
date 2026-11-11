import SwiftUI

struct LaunchSplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.443, green: 0.835, blue: 1.00), // #71D5FF
                         Color(red: 0.043, green: 0.137, blue: 0.427)], // #0B236D
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Image("LaunchLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 180)
                .scaleEffect(pulse ? 1.0 : 0.94)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
