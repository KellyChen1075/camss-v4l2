# OV9282 移植到 V4L2 + CamSS（QLI 1.9 / QCS6490 RB3 Gen2）步驟

路徑對照（你的 Ubuntu build host）：

```
K=~/qli-1.9/build-qcom-wayland/workspace/sources/linux-qcom-custom   # devtool workspace 的 kernel source
$K/drivers/media/i2c/ov9282.c                                         # sensor driver（upstream 現成）
$K/drivers/media/platform/qcom/camss/                                 # CamSS driver
$K/arch/arm64/boot/dts/qcom/qcs6490-rb3gen2.dts / qcs6490-addons-*.dts # board DT
```

本 repo 提供的檔案：

| 檔案 | 用途 |
|---|---|
| `scripts/check-kernel-tree.sh` | Step 0：檢查你的 kernel tree 能不能走這條路 |
| `kernel/ov9282-camss.cfg` | Step 2：kernel config fragment |
| `dts/qcs6490-rb3gen2-ov9282-camss.dtsi` | Step 3：DT 範本（以 upstream vision-mezzanine IMX577 overlay 為樣板） |
| `scripts/rb3-deploy.sh` | Step 5：推 `.ko` 到 RB3 |
| `scripts/ov9282-camss-setup.sh` | Step 6：media-ctl 設 pipeline |

整體概念：**ov9282.c 不用改（先不用）**，要做的只有三件事：
**(1) kernel config 打開、(2) DT 描述 sensor 怎麼接到哪顆 CSIPHY/CCI、(3) 把 downstream camera stack 關掉。**

---

## Step 0：先確認 kernel tree 支援（5 分鐘）

```sh
cd ~/camss-v4l2        # 本 repo clone 的位置
scripts/check-kernel-tree.sh
```

要看的結果：

| 檢查項目 | 若 FAIL |
|---|---|
| `camss.c supports qcom,sc7280-camss` | **最關鍵。** 沒有的話這份 kernel 的 CamSS 不支援 QCS6490，要 backport upstream camss（sc7280 CamSS 是近期 upstream 版本才加入），先停下來告訴我 kernel 版本 |
| `csid/vfe ... Y8 / GREY` | 只能拿 10-bit `Y10P`，GStreamer `v4l2src` 吃不下（見 trace 文件第 5 節） |
| `ov9282 supports Y8_1X8` | 同上，舊版 driver 只有 10-bit |
| `camss: ` / `cci0: ` / `cci1: ` 在 kodiak.dtsi 或 sc7280.dtsi | 沒有就要自己加 camss/cci node（從 upstream `kodiak.dtsi` 複製） |
| downstream camera nodes 清單 | Step 4 要關掉的對象 |
| 已有的 `ov9282` DT reference | **這就是你的硬體接線資訊來源**（Step 1） |

---

## Step 1：從 downstream（CamX）DT 抄出硬體接線

你熟悉的 Qualcomm 路徑已經把 OV9282 怎麼接描述在 downstream DT（`qcom,cam-sensor` node）和 sensor XML 裡，直接對照成 upstream 寫法：

| Downstream（CamX） | Upstream（V4L2 + CamSS） | 範本裡的位置 |
|---|---|---|
| `csiphy-sd-index = <N>` | `&camss { ports { port@N { reg = <N>; ... } } }` | `port@2` |
| `cci-device = <D>`（cci0/cci1）| `&cciD` | `&cci1` |
| `cci-master = <M>` | `&cciD_i2cM` | `&cci1_i2c0` |
| sensor XML `slaveAddress 0xC0`（8-bit） | `reg = <0x60>`（**7-bit，要右移 1**） | `camera@60` |
| MCLK clock `CAM_CC_MCLKn_CLK`、gpio | `clocks = <&camcc CAM_CC_MCLKn_CLK>`，pinctrl `gpio(64+n)` function `cam_mclk` | `MCLK2` / `gpio66` |
| reset gpio（`gpio-reset`） | `reset-gpios = <&tlmm X GPIO_ACTIVE_HIGH>` | `&tlmm 0` |
| `cam_vio` / `cam_vana` / `cam_vdig` | `dovdd-supply` / `avdd-supply` / `dvdd-supply` | |
| sensor XML lane 數 / data rate | `data-lanes = <1 2>`，`link-frequencies = <400000000>` | |

```sh
cd $K/arch/arm64/boot/dts/qcom
grep -rn -i -B5 -A40 "ov9282" .                     # downstream sensor node
grep -rn "csiphy-sd-index\|cci-master\|cci-device" . # 對照是哪一個
```

> 若 DT 在別的 layer（不在 kernel tree）：`grep -rln ov9282 ~/qli-1.9/layers` 或 `~/qli-1.9/build-qcom-wayland/tmp-glibc/work-shared`。
> sensor XML 通常在 camx / chi-cdk 的 `sensor/ov9282*/` 下。

**OV9282 driver 的硬限制（不符就 probe 失敗）**：MCLK **必須 24 MHz**、**2 lane**、`link-frequencies` **必須包含 400000000**。
如果你的模組是 1-lane 或跑別的頻率，就要改 `ov9282.c`（那時再處理）。

**reset 極性**：`ov9282_power_on()` 會 `gpiod_set_value(reset, 1)` 讓 sensor 開始運作，
所以 XCLR 高電位工作的話要寫 `GPIO_ACTIVE_HIGH`。（upstream IMX577 範例寫 `ACTIVE_LOW` 是因為那個 driver 語意相反，不要照抄。）

---

## Step 2：Kernel config

```sh
cd ~/qli-1.9 && source setup-environment     # 依你平常的方式進 build 環境
devtool menuconfig linux-qcom-custom
```

依 `kernel/ov9282-camss.cfg` 開啟（重點）：

```
CONFIG_SC_CAMCC_7280=y           # camera clock controller
CONFIG_I2C_QCOM_CCI=m            # upstream CCI (camera I2C)
CONFIG_VIDEO_QCOM_CAMSS=m        # Device Drivers → Multimedia → Media platform → Qualcomm
CONFIG_VIDEO_OV9282=m            # Device Drivers → Multimedia → Camera sensor devices
```

存檔後 devtool 會在 workspace 產生 config fragment。也可以把 `kernel/ov9282-camss.cfg`
加到 kernel recipe 的 `.bbappend`（`SRC_URI += "file://ov9282-camss.cfg"`），看 QLI recipe 是否支援 fragment。

驗證：

```sh
devtool build linux-qcom-custom
grep -E "QCOM_CAMSS|I2C_QCOM_CCI|OV9282|SC_CAMCC_7280" $(find ~/qli-1.9/build-qcom-wayland/tmp-glibc/work -path '*linux-qcom-custom*' -name .config | head -n1)
```

---

## Step 3：Device Tree

1. 先確認 RB3 **實際開的是哪個 dtb**（QLI 會依 board 從 dtb.bin 挑）：

   ```sh
   # 在 RB3 上
   cat /proc/device-tree/model; echo
   tr '\0' '\n' < /proc/device-tree/compatible
   ```

   對照 `qcs6490-rb3gen2.dts` / `qcs6490-addons-rb3gen2*.dts` 的 `model` 字串。

2. 把範本放進 kernel tree，填好 Step 1 的值（所有 `TODO`）：

   ```sh
   cp dts/qcs6490-rb3gen2-ov9282-camss.dtsi $K/arch/arm64/boot/dts/qcom/
   ```

3. 在**實際開機的那個 .dts 最後一行**加：

   ```dts
   #include "qcs6490-rb3gen2-ov9282-camss.dtsi"
   ```

範本重點（已用 upstream `qcs6490-rb3gen2.dts` 編譯驗證過語法，值要依你的硬體改）：

```dts
&camss {
	vdda-phy-supply = <&vreg_l10c_0p88>;
	vdda-pll-supply = <&vreg_l6b_1p2>;
	status = "okay";
	ports {
		port@2 {                               /* = CSIPHY2 */
			reg = <2>;
			ov9282_csiphy_ep: endpoint {
				clock-lanes = <7>;
				data-lanes = <0 1>;
				remote-endpoint = <&ov9282_ep>;
			};
		};
	};
};

&cci1 { status = "okay"; };

&cci1_i2c0 {
	camera@60 {
		compatible = "ovti,ov9282";
		reg = <0x60>;
		clocks = <&camcc CAM_CC_MCLK2_CLK>;
		assigned-clocks = <&camcc CAM_CC_MCLK2_CLK>;
		assigned-clock-rates = <24000000>;
		...
		port {
			ov9282_ep: endpoint {
				data-lanes = <1 2>;
				link-frequencies = /bits/ 64 <400000000>;
				remote-endpoint = <&ov9282_csiphy_ep>;
			};
		};
	};
};
```

---

## Step 4：關掉 downstream camera stack（衝突處理）

upstream `qcom-camss` / `i2c-qcom-cci` 和 downstream `cam_*`（CamX camera-kernel）會搶同一組
CSIPHY/CSID/IFE/CCI register、clock、GDSC。**只能留一邊。**

1. **DT**：Step 0 列出的 downstream node（`qcom,cam-cpas`, `qcom,cam-req-mgr`, `qcom,csiphy`, `qcom,csid`,
   `qcom,vfe`, `qcom,cci`, `qcom,cam-sensor` …）在同一個 dtsi 末尾 disable：

   ```dts
   &<downstream_label> { status = "disabled"; };
   ```

   特別注意：downstream CCI 和 upstream `cci0/cci1` 是同一個位址（`0xac4a000` / `0xac4b000`），兩個都 okay 一定衝突。

2. **Userspace**：停掉會去開 camera 的服務，避免載入 downstream module：

   ```sh
   # 在 RB3 上，名稱依 image 而定
   systemctl list-units | grep -iE "qmmf|cam"
   lsmod | grep -iE "camera|cam_"
   ```

   需要時加 `/etc/modprobe.d/blacklist-camx.conf`（`blacklist <downstream camera module>`）。

---

## Step 5：Build、燒錄、推 module

```sh
devtool build linux-qcom-custom
```

- **DT 有改 → 要更新 dtb**：重新產生 image（`devtool build-image <你的 image>` 或 `bitbake <image>`），
  再用你平常的方式燒 `dtb` / `boot` partition（QDL 或 fastboot）。
- **只改 `.c`** → 直接推 module（不用重燒）：

  ```sh
  scripts/rb3-deploy.sh modules ~/qli-1.9/build-qcom-wayland/tmp-glibc/work
  ```

---

## Step 6：在 RB3 上逐層驗證

```sh
# 1) driver 有 probe、sensor chip id 讀得到（0x9281）
dmesg | grep -iE "ov9282|camss|cci"
lsmod | grep -E "ov9282|qcom_camss|i2c_qcom_cci"

# 2) media graph 出現 ov9282 並 link 到 msm_csiphyN
media-ctl -d /dev/media0 -p | grep -A3 -i ov9282

# 3) 設 pipeline（CSIPHY 填 Step 1 的 N）並抓 raw
CSIPHY=2 sh ov9282-camss-setup.sh 8 1280x800
v4l2-ctl -d /dev/videoX --stream-mmap --stream-count=30 --stream-to=/tmp/ov9282.raw

# 4) GStreamer
gst-launch-1.0 v4l2src device=/dev/videoX ! video/x-raw,format=GRAY8,width=1280,height=800 ! \
  videoconvert ! jpegenc ! multifilesink location=/tmp/f%03d.jpg max-files=5
```

常見卡點對照：

| 卡在哪 | 訊息 | 檢查 |
|---|---|---|
| ov9282 沒 probe | 沒任何 ov9282 log | CCI node / `&cciD_i2cM` 是否對、`i2c_qcom_cci` 有沒有載入、`CONFIG_VIDEO_OV9282` |
| `inclk frequency mismatch` | | MCLK 不是 24 MHz（`assigned-clock-rates`） |
| `number of CSI2 data lanes` / `-EINVAL` | | `data-lanes` ≠ 2、沒有 400 MHz link-frequencies |
| `chip id mismatch` / I2C 錯誤 | | 7-bit 位址、reset 極性、電源、MCLK pinctrl |
| media graph 沒有 sensor→csiphy link | | camss 沒 probe（看 dmesg）、`remote-endpoint` 沒配對、port 號錯 |
| STREAMON 後沒 frame | | `port@N` 跟實際 CSIPHY 不符、lane 對應、downstream driver 仍在跑 |

---

## 之後可以再做的

- 確認 1280x800 Y8 出圖後，再試 10-bit（`Y10P` + 自寫 unpack 或 libcamera）。
- 曝光/增益：`v4l2-ctl -d /dev/v4l-subdevN -c exposure=...,analogue_gain=...`。
- 若 RB3 vision mezzanine 也接了 IMX577，可參考 upstream `qcs6490-rb3gen2-vision-mezzanine.dtso` 一起描述（不同 CSIPHY）。
