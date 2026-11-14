import SwiftUI

/// 启动覆盖层（纸本轨）：系统 launch screen 是纯纸底（UILaunchScreen → UIColorName
/// LaunchBackground），这里以同一纸色接住，只让「墨箭 + 朱砂承线」的记号淡入并轻呼吸，
/// 淡出时不会出现底色跳变。
///
/// 记号本身（LaunchLogo）是透明底 PNG，颜色取自纸本轨：墨 #1C1E1F / 朱砂 #A05243。
/// 若换成墨本深底启动，只需改这里的底色与 Info.plist 的 LaunchBackground 色值。
struct LaunchSplashView: View {
    @State private var risen = false

    var body: some View {
        ZStack {
            DWColor.paper.ignoresSafeArea()

            Image("LaunchLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 196)
                // 极轻的投影：让墨迹像压在纸上，而不是浮在屏幕里
                .shadow(color: DWColor.paperInk.opacity(0.08), radius: 10, y: 6)
                .scaleEffect(risen ? 1.0 : 0.955)
                .opacity(risen ? 1.0 : 0.72)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { risen = true }
        }
    }
}
