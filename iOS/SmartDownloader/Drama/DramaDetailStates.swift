import SwiftUI
import UIKit

// 加载 / 错误态——从 DramaDetailView.swift 逐字搬出（纯搬移，逻辑零改动）：
// 依赖只有 vm，以入参传入；loadingState / errorState 仍由主文件 body 调用（名字与签名不变）。

struct DramaDetailStates {
    let vm: DramaPageViewModel

    // MARK: - 加载 / 错误态

    var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(DWColor.paperCinnabar)
            Text("正在获取剧集列表…")
                .font(DWFont.cn(13))
                .foregroundStyle(DWColor.paperInkSub)
        }
    }

    func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(DWColor.paperCinnabar)
            Text(message)
                .font(DWFont.cn(13))
                .foregroundStyle(DWColor.paperInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            // 错误详情（用户要求 2026-11-15「把错误信息爆出来」）：
            // 系统那句「未能读取数据，因为它的格式不正确」只说现象，
            // 这里把 HTTP 状态 / Content-Type / 响应片段 / 站点身份原样摊开，
            // 并且可整段复制（真机排障时直接粘出来）
            if let detail = vm.loadErrorDetail {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DWColor.paperInkSub)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 132)
                .background(DWColor.paperChipIdle,
                            in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }
            HStack(spacing: 10) {
                if let detail = vm.loadErrorDetail {
                    Button {
                        UIPasteboard.general.string = detail
                        print("PLAYER_DBG [Entry] errorDetail copied chars=\(detail.count)")
                        vm.showToast("错误信息已复制")
                    } label: {
                        Text("复制错误信息")
                            .font(DWFont.cn(12, .medium))
                            .foregroundStyle(DWColor.paperInk)
                            .padding(.horizontal, 18)
                            .frame(height: 32)
                            .background(Capsule().fill(DWColor.paperChipSel))
                    }
                    .buttonStyle(.plain)
                }
                // 系统 borderedProminent 会有自己的强调色底，纸本轨用自己的胶囊（同下载页删除所选）
                Button {
                    vm.reload()
                } label: {
                    Text("重试")
                        .font(DWFont.cn(12, .medium))
                        .foregroundStyle(DWColor.paper)
                        .padding(.horizontal, 22)
                        .frame(height: 32)
                        .background(Capsule().fill(DWColor.paperCinnabar))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }
}
