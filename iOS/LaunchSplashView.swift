import SwiftUI

/// 启动覆盖层（纸本轨），逐值对齐画布 `19:273 LaunchScreen · 纸本`（390×844）：
/// 系统 launch screen 是纯纸底（`UILaunchScreen → UIColorName = LaunchBackground`），
/// 这里以同一纸色接住，再淡入「品牌区」——一笔墨符号 / 观 影 / 朱砂短线 / 副标，
/// 底部另有「智能下载」小字。淡出时底色不跳变。
///
/// 记号（`LaunchLogo`）由设计稿 `19:356 一笔墨 · 品牌符号` 导出，只做取景不改图形；
/// 颜色取自纸本轨：墨 `#1C1E1F` / 朱砂 `#A05243` / 次级墨 `#8C9190`。
struct LaunchSplashView: View {
    @State private var risen = false

    /// 品牌区内部间距：画布 19:355 为 VERTICAL + gap 24
    private let brandGap: CGFloat = 24

    var body: some View {
        ZStack {
            DWColor.paper.ignoresSafeArea()

            VStack(spacing: brandGap) {
                Image("LaunchLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)

                Text("观 影")
                    .font(DWFont.serif(34, .medium))
                    .tracking(8)
                    .foregroundStyle(DWColor.paperInk)

                // 画布 19:360：朱砂短线 36×2
                Rectangle()
                    .fill(DWColor.paperCinnabar)
                    .frame(width: 36, height: 2)

                Text("离线看，慢慢看")
                    .font(DWFont.serif(12))
                    .tracking(3)
                    .foregroundStyle(DWColor.paperInkSub)
            }
            .scaleEffect(risen ? 1.0 : 0.97)
            .opacity(risen ? 1.0 : 0.0)
        }
        // 画布 19:362：底部字「智能下载」，距画幅底约 38（这里相对安全区留 6）
        .overlay(alignment: .bottom) {
            Text("智能下载")
                .font(DWFont.cn(11))
                .foregroundStyle(DWColor.overlayInkSub)   /* P1-⑪：裸 hex 收口到 token（同值） */
                .padding(.bottom, 6)
                .opacity(risen ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { risen = true }
        }
    }
}
