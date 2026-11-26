#!/usr/bin/env bash
# 在 LineageOS 20 内核树里编译 cannon（MT6853）4.14.336，并启用 USB 音频 gadget（UAC2）
# 注意：本脚本假设当前目录就是内核源码树根（CI 里由 actions/checkout 提供）
set -euo pipefail

OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CC_BIN="${CC_BIN:-clang-14}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
CROSS32="${CROSS32:-arm-linux-gnueabi-}"
CLANG_TRIPLE="${CLANG_TRIPLE:-aarch64-linux-gnu-}"

# 4.14 老代码在 clang-14 下的新增告警不该判死
KCFLAGS="${KCFLAGS:--Wno-unknown-warning-option -Wno-error -Wno-error=strict-prototypes -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=format -Wno-error=unused-but-set-variable -Wno-error=misleading-indentation -Wno-error=implicit-fallthrough}"

mkdir -p "$OUT"

echo "== 生成 .config：k6853v1_64_defconfig + cannon_defconfig + UAC2"
make O="$OUT" ARCH=arm64 k6853v1_64_defconfig
cat arch/arm64/configs/cannon_defconfig >> "$OUT/.config"
{
	echo '# CONFIG_DEBUG_INFO is not set'  # 不要调试信息：省一半编译时间，且避免 DWARF5 让老 objdump 刷屏
	echo '# CONFIG_MTK_LOAD_TRACKER is not set'
	echo 'CONFIG_SND=y'
	echo 'CONFIG_SND_PCM=y'
	echo 'CONFIG_USB_F_UAC2=y'
	echo 'CONFIG_USB_CONFIGFS_F_UAC2=y'
} >> "$OUT/.config"
# LTO：cannon_defconfig 里是 CONFIG_LTO_CLANG=y（ThinLTO），GNU gold 不支持
# --thinlto-cache-dir，vdso 链接会失败。这里显式选 LTO_NONE。
scripts/config --file "$OUT/.config" -e LTO_NONE -d LTO_CLANG -d THINLTO -d LTO || true
make O="$OUT" ARCH=arm64 olddefconfig >/dev/null
echo "== LTO 状态"
grep -E '^CONFIG_(LTO|LTO_CLANG|LTO_NONE|THINLTO)' "$OUT/.config" || echo '   (无 LTO 相关符号)'
grep -q '^CONFIG_LTO_CLANG=y' "$OUT/.config" && { echo "错误：LTO_CLANG 仍然开启" >&2; exit 1; } || true

echo "== 核对关键配置"
for k in CONFIG_SND CONFIG_SND_PCM CONFIG_USB_GADGET CONFIG_USB_CONFIGFS CONFIG_USB_F_UAC2 CONFIG_USB_CONFIGFS_F_UAC2 CONFIG_USB_CONFIGFS_MASS_STORAGE CONFIG_USB_CONFIGFS_RNDIS CONFIG_MTK_COMBO_WIFI; do
	printf '   %-36s %s\n' "$k" "$(sed -n "s/^${k}=//p" "$OUT/.config" | head -1)"
done
grep -q '^CONFIG_USB_CONFIGFS_F_UAC2=y' "$OUT/.config" || { echo "错误：UAC2 未启用" >&2; exit 1; }

echo "== 编译 Image（-j$JOBS, CC=$CC_BIN）"
make O="$OUT" ARCH=arm64 \
	CC="$CC_BIN" CLANG_TRIPLE="$CLANG_TRIPLE" \
	CROSS_COMPILE="$CROSS" CROSS_COMPILE_ARM32="$CROSS32" \
	KCFLAGS="$KCFLAGS" -j"$JOBS" Image

cp "$OUT/arch/arm64/boot/Image" "$OUT/Image"

echo "== 校验"
python3 - "$OUT/Image" <<'PY'
import struct, sys, os
p = sys.argv[1]
d = open(p, 'rb').read(64)
assert d[56:60] == b'ARM\x64', '不是 arm64 Image'
off = struct.unpack('<Q', d[8:16])[0]
print('   size=%d  text_offset=0x%x（期望 0x80000）' % (os.path.getsize(p), off))
assert off == 0x80000, 'text_offset 不对，LK 装不起来'
PY
[ -f "$OUT/drivers/usb/gadget/function/f_uac2.o" ] || { echo "错误：f_uac2.o 未生成" >&2; exit 1; }
echo "   f_uac2.o 已生成"
echo "完成: $OUT/Image"
