#!/bin/bash
# 三机型快照矩阵（AGENTS「布局缩放与机型适配」第 3 条；2026-11-16 首跑全 PASS，见 HANDOFF §5）
#
# 用法:  bash snapshot3.sh [设备名1 设备名2 设备名3]
# 默认:  SE3-快照(375×667 小屏) / iPhone 17 Pro(402×874 标准) / iPhone 17 Pro Max(Max)
#        「SE3-快照」是 simctl create 的 SE 3 代 iOS 26.5 模拟器（iOS 26 无预置 SE，
#        首次需: xcrun simctl create "SE3-快照" "iPhone SE (3rd generation)" \
#          com.apple.CoreSimulator.SimRuntime.iOS-26-5）
#
# 每台设备截 5 态: 详情页顶部/页底 · 播放页竖屏/全屏 · 下载页
# 样张: 自动从任一既有模拟器容器发现「横屏样张」（3 集 1280×720 真片源）；
#       一台都没有时需先手工造（SMARTDOWNLOADER_DIR 下 剧名/第NN集/playlist.m3u8 + seg_*.ts）
# 输出:  /tmp/snapshots/<标签>-<状态>.png（标签取设备名去空格）
#
# 注意: 重装 App 会换数据容器、清掉旧样张——本脚本每台先灌样张再截（首轮踩过：
#       先 find 到旧容器路径当源，install 后旧容器被清 → cp 失败 → 播放页/下载页空态）。
set -u

APP="${APP:-/private/var/folders/bj/3nsy0tm55szbh76_dn499ghr0000gn/T/opencode/fix3-dd/Build/Products/Debug-iphonesimulator/SmartDownloader.app}"
OUT="${OUT:-/tmp/snapshots}"
BUNDLE=com.firefish.smartdownloader
# 无参数时三台默认设备；注意不能写 DEVICES=("${@:-a b c}")——那样会把三个名字并成一个串
if [ $# -gt 0 ]; then DEVICES=("$@"); else DEVICES=("SE3-快照" "iPhone 17 Pro" "iPhone 17 Pro Max"); fi

mkdir -p "$OUT"

# ── 样张源：从既有模拟器容器里找一份现成的「横屏样张」──
SAMPLE_SRC=$(find ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents/Downloads \
  -maxdepth 1 -name "横屏样张" -type d 2>/dev/null | head -1)
[ -z "$SAMPLE_SRC" ] && { echo "没有发现样张源，先在任一模拟器上准备「横屏样张」"; exit 1; }
echo "样张源: $SAMPLE_SRC"
# 先拷到中性位置：源可能就在待 install 设备的旧容器里，install 换容器后旧路径失效
#（首轮踩过：SE3 先跑成功、轮到源所在的 iPhone 17 Pro 时 cp 找不到旧容器）
STAGING="$OUT/_sample_src"
rm -rf "$STAGING" && mkdir -p "$(dirname "$STAGING")"
cp -R "$SAMPLE_SRC" "$STAGING" || { echo "样张暂存失败"; exit 1; }

find_udid() {  # 设备名 → UDID（行首缩进 + 名字 + 空格 + (UDID)；精确到名字后跟 (，避免 17 Pro 误中 17 Pro Max）
  xcrun simctl list devices available | grep -E "^[[:space:]]+$1 \([0-9A-F-]{36}\)" | tail -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

for name in "${DEVICES[@]}"; do
  udid=$(find_udid "$name")
  [ -z "$udid" ] && { echo "找不到设备: $name"; continue; }
  label=$(echo "$name" | tr -d ' ')
  echo "== boot $name ($udid) =="

  xcrun simctl boot "$udid" 2>/dev/null
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$APP"

  # 灌样张（install 可能换容器，必须在 install 之后取容器路径）
  container=$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)
  mkdir -p "$container/Documents/Downloads"
  rm -rf "$container/Documents/Downloads/横屏样张"
  cp -R "$STAGING" "$container/Documents/Downloads/横屏样张" || { echo "SEED FAILED: $name"; exit 1; }

  states=(
    "detail-top|-dramaPreview"
    "detail-bottom|-dramaPreview -dramaPreviewBottom"
    "player-portrait|-playerPreview -playerPinControls"
    "player-fullscreen|-playerPreview -playerFullscreen -playerPinControls"
    "downloads|-startDownloadedPage"
  )
  for s in "${states[@]}"; do
    st="${s%%|*}"; args="${s#*|}"
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null
    xcrun simctl launch "$udid" "$BUNDLE" $args >/dev/null
    sleep 8   # splash 1.2s + 样张延时 1.5s + 片头起播
    xcrun simctl io "$udid" screenshot "$OUT/${label}-${st}.png" 2>/dev/null \
      && echo "shot: ${label}-${st}" || echo "SHOT FAILED: ${label}-${st}"
  done
  xcrun simctl shutdown "$udid"
done
echo ALL_DONE
