#!/bin/sh
# Configure the upstream qcom-camss media graph for an OV9282 sensor:
#   ov9282 -> msm_csiphy<N> -> msm_csid<M> -> msm_vfe<K>_rdi<R> -> msm_vfe<K>_video<R>
#
# Usage: ov9282-camss-setup.sh [8|10] [WxH]
# Env:   MEDIA=/dev/media0 CSIPHY=0 CSID=0 VFE=0 RDI=0
#
# 8-bit  -> Y8_1X8   -> V4L2 GREY -> GStreamer GRAY8   (needs gen2 CSID / 845-class VFE)
# 10-bit -> Y10_1X10 -> V4L2 Y10P (MIPI packed, not understood by v4l2src)
set -eu

BITS=${1:-8}
SIZE=${2:-1280x800}
MEDIA=${MEDIA:-/dev/media0}
CSIPHY=${CSIPHY:-0}
CSID=${CSID:-0}
VFE=${VFE:-0}
RDI=${RDI:-0}

case "$BITS" in
	8)  CODE=Y8_1X8;   PIXFMT=GREY ;;
	10) CODE=Y10_1X10; PIXFMT=Y10P ;;
	*)  echo "bits must be 8 or 10" >&2; exit 1 ;;
esac

MC="media-ctl -d $MEDIA"
FMT="fmt:$CODE/$SIZE field:none"

SENSOR=$($MC -p | sed -n 's/.*entity [0-9]*: \(ov9282 [^ ]*\).*/\1/p' | head -n1)
if [ -z "$SENSOR" ]; then
	echo "ov9282 entity not found in $MEDIA (check dmesg: probe / async bind)" >&2
	exit 1
fi

PHY="msm_csiphy$CSIPHY"
CSID_E="msm_csid$CSID"
RDI_E="msm_vfe${VFE}_rdi$RDI"
CSID_SRC=$((1 + RDI))	# MSM_CSID_PAD_FIRST_SRC + rdi index

$MC --reset
$MC -l "\"$PHY\":1->\"$CSID_E\":0[1]"
$MC -l "\"$CSID_E\":$CSID_SRC->\"$RDI_E\":0[1]"

$MC -V "\"$SENSOR\":0[$FMT]"
$MC -V "\"$PHY\":0[$FMT]"
$MC -V "\"$CSID_E\":0[$FMT]"
$MC -V "\"$CSID_E\":$CSID_SRC[$FMT]"
$MC -V "\"$RDI_E\":0[$FMT]"

VIDEO=$($MC -e "msm_vfe${VFE}_video$RDI")
W=${SIZE%x*}
H=${SIZE#*x}
v4l2-ctl -d "$VIDEO" --set-fmt-video=width=$W,height=$H,pixelformat=$PIXFMT

echo "sensor : $SENSOR ($($MC -e "$SENSOR"))"
echo "video  : $VIDEO ($PIXFMT ${W}x${H})"
echo
echo "test   : v4l2-ctl -d $VIDEO --stream-mmap --stream-count=100 --stream-to=/tmp/ov9282.raw"
if [ "$BITS" = 8 ]; then
	echo "gst    : gst-launch-1.0 v4l2src device=$VIDEO ! video/x-raw,format=GRAY8,width=$W,height=$H ! videoconvert ! fakesink"
fi
