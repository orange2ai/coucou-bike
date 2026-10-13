#!/bin/bash
# 咕咕骑车 冒烟测试 —— 推送前的强制关卡
#
# 覆盖（每一项都对应一次真实事故）：
#   1. xcodegen 重新生成工程，杜绝"改了 project.yml 忘了 regenerate"
#   2. 模拟器全量编译
#   3. 单元测试（工程完整性 + 卡尔曼 + 实时活动 + 设置解码）
#   4. 装机产物 Info.plist 完整性（后台定位/实时活动/启动屏/appex NSExtension）
#   5. 模拟器安装 + 启动存活
#   6. 真实骑行生命周期（-autoRide 开骑 → -autoEnd 结束 → 结算页），全程进程存活
#
# 紧急跳过：COUCOU_SKIP_SMOKE=1 git push（原因必须写进提交信息）
set -euo pipefail
cd "$(dirname "$0")/.."

step() { echo -e "\n=== [冒烟] $1 ==="; }
fail() { echo "❌ [冒烟] $1"; exit 1; }

step "xcodegen 生成工程"
xcodegen generate

step "选取可用模拟器"
SIM_ID=$(xcrun simctl list devices available | grep -m1 -E "iPhone" | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/')
[ -n "$SIM_ID" ] || fail "没有可用的 iPhone 模拟器"
echo "模拟器: $SIM_ID"

# 收尾：不管成功失败，都把 App 杀掉；本脚本自己启动的模拟器顺手关掉（不留下常驻定位/实时活动）
WAS_BOOTED=$(xcrun simctl list devices | grep "$SIM_ID" | grep -c "Booted" || true)
cleanup() {
  xcrun simctl terminate "$SIM_ID" ai.marswave.coucou > /dev/null 2>&1 || true
  if [ "$WAS_BOOTED" -eq 0 ]; then
    xcrun simctl shutdown "$SIM_ID" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

DD=/tmp/coucou-smoke-dd

step "模拟器全量编译"
if xcodebuild -project coucou.xcodeproj -scheme coucou -destination "id=$SIM_ID" \
     -derivedDataPath "$DD" build > /tmp/smoke_build.log 2>&1; then
  grep -E "BUILD (SUCCEEDED|FAILED)" /tmp/smoke_build.log | tail -1
else
  grep -E "error:" /tmp/smoke_build.log | sort -u | head -10
  fail "编译失败"
fi

APP="$DD/Build/Products/Debug-iphonesimulator/coucou.app"
[ -d "$APP" ] || fail "找不到编译产物 $APP"

step "单元测试"
if xcodebuild test -project coucou.xcodeproj -scheme coucou -destination "id=$SIM_ID" \
     -derivedDataPath "$DD" > /tmp/smoke_test.log 2>&1; then
  grep -E "Test Suite 'SmokeTests'" /tmp/smoke_test.log | tail -1
else
  grep -E "error:|failed" /tmp/smoke_test.log | sort -u | head -20
  fail "单元测试失败"
fi

step "装机产物完整性（Info.plist / appex）"
python3 - "$APP" << 'PYEOF'
import plistlib, sys, os
app = sys.argv[1]
def load(p):
    with open(p, "rb") as f: return plistlib.load(f)
info = load(os.path.join(app, "Info.plist"))
modes = info.get("UIBackgroundModes", [])
assert "location" in modes and "audio" in modes, f"UIBackgroundModes 异常: {modes}"
assert info.get("NSSupportsLiveActivities") is True, "缺 NSSupportsLiveActivities"
assert info.get("UILaunchScreen"), "缺 UILaunchScreen"
appex = os.path.join(app, "PlugIns", "coucouWidgets.appex")
assert os.path.isdir(appex), "coucouWidgets.appex 未嵌入"
ext = load(os.path.join(appex, "Info.plist")).get("NSExtension", {})
assert ext.get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension", "appex 缺 NSExtension"
print("Info.plist / appex 全部通过")
PYEOF

step "模拟器安装 + 启动存活"
xcrun simctl bootstatus "$SIM_ID" -b > /dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl terminate "$SIM_ID" ai.marswave.coucou 2>/dev/null || true
xcrun simctl launch "$SIM_ID" ai.marswave.coucou -fakeSummary > /dev/null
sleep 4
ALIVE=$(xcrun simctl spawn "$SIM_ID" launchctl list 2>/dev/null | grep -c "ai.marswave.coucou" || true)
[ "$ALIVE" -ge 1 ] || fail "启动后进程消失（闪退）"
echo "启动存活 ✓"

step "骑行生命周期（-autoRide 开骑 → 68 秒后 -autoEnd 结束 → 结算页）"
xcrun simctl terminate "$SIM_ID" ai.marswave.coucou 2>/dev/null || true
xcrun simctl launch "$SIM_ID" ai.marswave.coucou -autoRide -autoEnd > /dev/null
sleep 78
ALIVE=$(xcrun simctl spawn "$SIM_ID" launchctl list 2>/dev/null | grep -c "ai.marswave.coucou" || true)
[ "$ALIVE" -ge 1 ] || fail "骑行生命周期中进程消失（GO/结算页闪退）"
echo "骑行生命周期存活 ✓"

cleanup
trap - EXIT
echo "清理：已杀掉 App，模拟器已收工"

echo -e "\n✅ 冒烟测试全部通过"
