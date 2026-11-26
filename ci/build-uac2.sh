#!/usr/bin/env bash
# 在 LineageOS 20 内核树里编译 cannon（MT6853 / 4.14.336-perf-cus），只加 USB 音频(UAC2)
# 严格按官方构建配方：单一 cannon_defconfig（device/xiaomi/cannon BoardConfig.mk: TARGET_KERNEL_CONFIG）
# 且 KERNEL_LD := LD=ld.lld（BoardConfig.mk），clang 工具链。
set -euo pipefail

OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CC_BIN="${CC_BIN:-clang-14}"
LD_BIN="${LD_BIN:-ld.lld}"          # 与官方 KERNEL_LD 一致
CROSS="${CROSS:-aarch64-linux-gnu-}"
CROSS32="${CROSS32:-arm-linux-gnueabi-}"
CLANG_TRIPLE="${CLANG_TRIPLE:-aarch64-linux-gnu-}"
DEFCONFIG="${DEFCONFIG:-cannon_defconfig}"

KCFLAGS="${KCFLAGS:--Wno-unknown-warning-option -Wno-error -Wno-error=strict-prototypes -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=format -Wno-error=unused-but-set-variable -Wno-error=misleading-indentation -Wno-error=implicit-fallthrough}"

mkdir -p "$OUT"
command -v "$CC_BIN" >/dev/null || { echo "缺少 $CC_BIN" >&2; exit 1; }
command -v "$LD_BIN" >/dev/null || { echo "缺少 $LD_BIN" >&2; exit 1; }

echo "== 生成 .config（$DEFCONFIG）"
make O="$OUT" ARCH=arm64 "$DEFCONFIG"

echo "== 只追加 UAC2（其他全部保持官方默认）"
{
	echo 'CONFIG_SND=y'
	echo 'CONFIG_SND_PCM=y'
	echo 'CONFIG_USB_F_UAC2=y'
	echo 'CONFIG_USB_CONFIGFS_F_UAC2=y'
} >> "$OUT/.config"
make O="$OUT" ARCH=arm64 olddefconfig >/dev/null

echo "== 配置核对"
check() { printf '   %-36s %s\n' "$1" "$(sed -n "s/^$1=//p" "$OUT/.config" | head -1)"; }
for k in CONFIG_USB_F_UAC2 CONFIG_USB_CONFIGFS_F_UAC2 CONFIG_SND CONFIG_SND_PCM \
         CONFIG_USB_GADGET CONFIG_USB_CONFIGFS CONFIG_USB_CONFIGFS_MASS_STORAGE CONFIG_USB_CONFIGFS_RNDIS \
         CONFIG_MTK_COMBO CONFIG_MTK_COMBO_WIFI CONFIG_CFG80211 \
         CONFIG_MTK_LOAD_TRACKER CONFIG_MTK_TOPO_CTRL CONFIG_LTO_CLANG CONFIG_DEBUG_INFO CONFIG_LOCALVERSION; do
	check "$k"
done
grep -q '^CONFIG_USB_CONFIGFS_F_UAC2=y' "$OUT/.config" || { echo "错误：UAC2 未启用" >&2; exit 1; }

echo "== 编译 Image（-j$JOBS, CC=$CC_BIN, LD=$LD_BIN）"
make O="$OUT" ARCH=arm64 \
	CC="$CC_BIN" LD="$LD_BIN" CLANG_TRIPLE="$CLANG_TRIPLE" \
	CROSS_COMPILE="$CROSS" CROSS_COMPILE_ARM32="$CROSS32" \
	KCFLAGS="$KCFLAGS" -j"$JOBS" Image

cp "$OUT/arch/arm64/boot/Image" "$OUT/Image"
cp "$OUT/.config" "$OUT/config.final.txt"   # 供下载核对（dot 文件会被 artifact 忽略）

echo "== 校验"
python3 - "$OUT/Image" <<'PY'
import struct, sys, os
p = sys.argv[1]
d = open(p,'rb').read(64)
assert d[56:60] == b'ARM\x64', '不是 arm64 Image'
off = struct.unpack('<Q', d[8:16])[0]
print('   size=%d  text_offset=0x%x' % (os.path.getsize(p), off))
assert off == 0x80000
PY
[ -f "$OUT/drivers/usb/gadget/function/f_uac2.o" ] || { echo "错误：f_uac2.o 未生成" >&2; exit 1; }
echo "   f_uac2.o 已生成"
echo "完成: $OUT/Image"
