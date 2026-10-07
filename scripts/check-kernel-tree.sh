#!/bin/sh
# Step 0: check whether a kernel tree can do OV9282 over upstream qcom-camss.
# Run on the Ubuntu build host.
#
# Usage: check-kernel-tree.sh [kernel_src_dir]
#   default: ~/qli-1.9/build-qcom-wayland/workspace/sources/linux-qcom-custom
set -u

K=${1:-$HOME/qli-1.9/build-qcom-wayland/workspace/sources/linux-qcom-custom}
DTS=$K/arch/arm64/boot/dts/qcom
CAMSS=$K/drivers/media/platform/qcom/camss

cd "$K" || exit 1

section() { printf '\n== %s ==\n' "$1"; }
check() {	# check <description> <command...>
	desc=$1
	shift
	if "$@" >/dev/null 2>&1; then echo "[ OK ] $desc"; else echo "[FAIL] $desc"; fi
}

section "kernel version"
make -s kernelversion 2>/dev/null || head -n 5 Makefile

section "upstream CamSS for QCS6490 (sc7280)"
check "camss driver exists"                  test -f "$CAMSS/camss.c"
check "camss.c supports qcom,sc7280-camss"   grep -q '"qcom,sc7280-camss"' "$CAMSS/camss.c"
check "csid gen2 formats contain Y8_1X8"     grep -q 'MEDIA_BUS_FMT_Y8_1X8' "$CAMSS/camss-csid.c"
check "vfe RDI formats contain Y8 -> GREY"   grep -q 'V4L2_PIX_FMT_GREY' "$CAMSS/camss-vfe.c"
check "upstream CCI driver exists"           test -f drivers/i2c/busses/i2c-qcom-cci.c

section "OV9282 sensor driver"
check "ov9282.c exists"                      test -f drivers/media/i2c/ov9282.c
check "ov9282 supports Y8_1X8 (8-bit)"       grep -q 'MEDIA_BUS_FMT_Y8_1X8' drivers/media/i2c/ov9282.c
grep -n 'define OV9282_INCLK_RATE\|define OV9282_LINK_FREQ\|define OV9282_NUM_DATA_LANES' \
	drivers/media/i2c/ov9282.c

section "device tree: which SoC dtsi does the board include"
grep -n '#include' "$DTS/qcs6490-rb3gen2.dts" | grep -v dt-bindings
for f in kodiak.dtsi sc7280.dtsi; do
	[ -f "$DTS/$f" ] || continue
	echo "-- $f"
	grep -n 'camss: \|cci0: \|cci1: \|compatible = "qcom,sc7280-camss"\|compatible = "qcom,sc7280-cci"' "$DTS/$f"
done

section "board regulators used by the camss node (labels must exist)"
grep -n 'vreg_l10c_0p88: \|vreg_l6b_1p2: \|vreg_l18b_1p8: ' "$DTS/qcs6490-rb3gen2.dts"

section "downstream (CamX) camera nodes that would conflict"
grep -rln 'qcom,cam-\|qcom,csiphy\|qcom,cam-sensor\|qcom,cci"' "$DTS" 2>/dev/null | head -n 20

section "existing ov9282 references in DT (downstream sensor node = wiring info)"
grep -rn -i 'ov9282' "$DTS" 2>/dev/null | head -n 20

section "kernel config (build dir .config, if found)"
CFG=$(find "$K/../../../tmp-glibc/work" -path '*linux-qcom-custom*' -name .config 2>/dev/null | head -n1)
if [ -n "$CFG" ]; then
	echo "$CFG"
	grep -E 'CONFIG_(VIDEO_QCOM_CAMSS|I2C_QCOM_CCI|VIDEO_OV9282|SC_CAMCC_7280|V4L_PLATFORM_DRIVERS|VIDEO_CAMERA_SENSOR)[= ]' "$CFG" ||
		echo "(none of the camss/ov9282 options are set)"
else
	echo "no .config found; run 'devtool build linux-qcom-custom' first"
fi
