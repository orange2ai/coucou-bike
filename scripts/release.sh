#!/bin/bash
# 咕咕骑车 正式发版关卡 —— 每次发版前必须完整通过一次
#
# 用法: scripts/release.sh [版本号，可选，如 0.2.0]
#
# 流程: 全量冒烟（编译+单测+装机产物+启动+骑行生命周期）
#       → 真机编译装机 → 人工实测清单
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== [发版] 第 1 步：全量冒烟测试 ==="
./scripts/smoke.sh

echo "=== [发版] 第 2 步：真机编译 + 装机 ==="
xcodebuild -project coucou.xcodeproj -scheme coucou -destination 'generic/platform=iOS' \
     -allowProvisioningUpdates build > /tmp/release_build.log 2>&1 \
  || { grep -E "error:" /tmp/release_build.log | sort -u | head -10; echo "❌ 真机编译失败"; exit 1; }
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "coucou.app" -path "*iphoneos*" -newermt "-3 minutes" | head -1)
if xcrun devicectl device install app --device 9FEED4F4-476D-58CE-B8E0-CB96EA35D3C2 "$APP" 2>&1 | grep -qiE "installed"; then
  echo "真机安装 ✓"
else
  echo "⚠️ 真机未连接，跳过装机——发版前必须人工补装并实测"
fi

echo "=== [发版] 第 3 步：人工实测清单（逐项打勾后才能提审/发布）==="
cat << 'LIST'
  [ ] 首次安装：健康读取授权弹窗出现、措辞为只读，授权后记录页有数据
  [ ] 拒绝授权：记录页为空且给出提示，不闪退、不反复弹窗
  [ ] 记录页：总里程与健康 App 里的骑行距离合计对得上
  [ ] 柱状图日/周/月切换正常，点柱子出单段数字
  [ ] 骑行日历：近 26 周橙点密度与真实骑行日期一致，点格子能联动
  [ ] 历史列表点进详情：距离/用时/均速/千卡/爬升/心率与健康里那次训练一致
  [ ] 导出 Markdown：分享面板能出文件，内容含心率、每公里分段与轨迹点
  [ ] 杀 App 重启：无白屏、无残留
  [ ] 设置页：权限状态显示正确，原则文案与当前产品一致
LIST

if [ -n "${1:-}" ]; then
  echo "=== [发版] 版本号: $1（请在 project.yml 更新 MARKETING_VERSION 后重新冒烟一次）==="
fi
echo -e "\n✅ 发版关卡完成（人工清单勾完才算真正通过）"
