#!/bin/bash
# 把 .app 打成可分发的 .dmg。
#
# 用法:
#   bash shell/scripts/build-dmg.sh <app路径> <输出dmg路径>
#
# 为什么发 dmg 而不是 zip：
#   Apple 要求「先打包再提交公证」—— .app 目录本身不能直接提交 notarytool。
#   而公证成功后的 ticket 又**不能 staple 回 .zip**。走 zip 就得
#   「打包 zip → 公证 → 解压 → staple → 重新打包」绕两趟。
#   发 dmg 就干净了：notarytool 原生接受 dmg (UDIF)，公证后用户下载 dmg，
#   首次启动时 Gatekeeper 联网校验即可。staple 只是离线场景的优化，可不做。
#
# 产物格式 UDZO = 经 zlib 压缩的 UDIF，是 macOS 分发的标准格式。
set -eu

APP_PATH="${1:?用法: build-dmg.sh <app路径> <输出dmg路径>}"
OUT_DMG="${2:?用法: build-dmg.sh <app路径> <输出dmg路径>}"

command -v hdiutil >/dev/null || { echo "需要 hdiutil（macOS 自带）"; exit 1; }
[ -d "$APP_PATH" ] || { echo "找不到 .app: $APP_PATH"; exit 1; }

VOL_NAME="$(basename "$APP_PATH" .app)"

# staging 放临时目录，不放仓库里：
# 同步盘（iCloud/Dropbox）会给 .app 重新挂上 Finder metadata，
# 导致 codesign 后的签名失效、公证报 "code signature is invalid"。
STAGE="$(mktemp -d /tmp/dmgstage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> 拼装 dmg 内容"
cp -a "$APP_PATH" "$STAGE/"
# 给 dmg 里的 Applications 快捷方式，拖进去就能装
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT_DMG")"
rm -f "$OUT_DMG"

echo "==> 打 dmg (UDZO)"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" \
	-fs HFS+ -fsargs "-c c=64,a=16,e=16" \
	-format UDZO -ov "$OUT_DMG" >/dev/null

if sig_out=$(codesign --verify --deep --strict "$APP_PATH" 2>&1); then
	echo "    签名校验: 通过"
else
	echo "    签名校验: 失败（dmg 仍可分发，但公证会拒）"
	# 失败原因必须打出来，否则日志里只有「失败」两个字，无从排查。
	printf '      %s\n' "$sig_out" | head -5
	# 已知一类：venv 里的绝对符号链接（bin/python3 -> /绝对路径/基础解释器）
	# 会报「invalid destination for symbolic link in bundle」。
	# 这是硬约束：codesign 不允许 bundle 内有指向外部路径的符号链接，
	# 所以只要用 venv，这个签名就永远是无效的 —— 不是调参能解决的。
fi

echo
echo "==> 完成: $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1))"
