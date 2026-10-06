# OV9282：從 Kernel 一路 trace 到 GStreamer（upstream qcom-camss / V4L2 路徑）

> 依據：upstream Linux `master` 的 `drivers/media/i2c/ov9282.c`、
> `drivers/media/platform/qcom/camss/*`，以及 GStreamer `gst-plugins-good/sys/v4l2/gstv4l2object.c`。
> 行號會隨版本變動，以函式名稱為準。

---

## 0. 先講結論（給熟 Qualcomm CamX 路徑的人）

| 項目 | Qualcomm 路徑（右邊：CamX/CHI + IFE/IPE） | Upstream V4L2 路徑（左邊：qcom-camss） |
|---|---|---|
| Kernel driver | downstream `camera-kernel`（`cam_sensor`, `cam_csiphy`, `cam_ife_csid`, `cam_isp`, `cam_icp`…） | upstream `ov9282.c` + `qcom-camss`（`camss.c`, `camss-csiphy.c`, `camss-csid.c`, `camss-vfe.c`） |
| Sensor 設定方式 | userspace sensor XML / `.so` driver，kernel 只做 CCI 傳輸 | **kernel** sensor driver（`ov9282.c`）自己寫暫存器 |
| ISP | IFE / IPE / BPS 全功能 | **只用 RDI（raw dump）**，不經 ISP |
| 3A | CamX 3A | 無（要自己做 AE，或交給 libcamera） |
| GStreamer element | `qtiqmmfsrc` | `v4l2src`（或 `libcamerasrc`） |
| 輸出格式 | NV12 / UBWC 等 | `GREY` (8-bit) / `Y10P` / `Y10` |

**「綁 CamSS 會發生甚麼事」**

1. **兩套 driver 搶同一塊硬體。** `qcom-camss` 與 downstream `cam_*` driver 都會去 claim 同樣的
   CSIPHY / CSID / IFE(VFE) register、clock、GDSC power domain、interconnect。DT 裡**只能啟用一邊**：
   用 upstream 就要把 `cam_*` 相關 node `status = "disabled"`（或乾脆不 build camera-kernel），
   反之亦然。兩邊同時開會 probe 失敗或更糟（register 被互相改）。
2. **CamX / qmmf-server / `qtiqmmfsrc` 全部不能用。** 它們只認 downstream 的 `/dev/video*`（cam_req_mgr）介面。
3. **沒有 IFE/IPE ISP 處理。** upstream CamSS 的 VFE 在新平台（SDM845 之後，含 SC7280/QCS6490）
   基本上只開 RDI：例如 `vfe_res_7280` 的 `.line_num = 3`，只建立 RDI0~2（`VFE_LINE_PIX = 3` 不會被建立）；
   而且所有 PIX 格式表（`formats_pix_8x16/8x96/845`）都只有 YUV → NV12/NV16 等，沒有任何 Y8/Y10。
   → **OV9282 是黑白 sensor，本來就不需要 demosaic，所以走 RDI raw dump 反而剛好。**
   你拿到的是 sensor 原始灰階 + 黑電平，沒有 BLC/LSC/denoise。
4. **曝光/增益要自己控。** 透過 sensor subdev 的 V4L2 control（`V4L2_CID_EXPOSURE`,
   `V4L2_CID_ANALOGUE_GAIN`, `V4L2_CID_VBLANK`…）手動設，或用 libcamera 的 AE。

---

## 1. 整條路徑總覽

```
 [ OV9282 ] --MIPI CSI-2 D-PHY, 2 lane, 400 MHz--> [ CSIPHYn ] --> [ CSIDm ] --> [ VFEk RDIx ] --DMA--> vb2 buffer
     ^ I2C/CCI (0x60)                                                                                     |
     |                                                                                                    v
 ov9282.c (v4l2_subdev, /dev/v4l-subdevX)       camss-*.c (v4l2_subdev × N + video_device)      /dev/videoY ("msm_vfeK_videoX")
                                                                                                          |
                                                              media-ctl 設 link / format                   v
                                                                                           GStreamer v4l2src (gstv4l2object.c)
                                                                                                          |
                                                                                           video/x-raw,format=GRAY8 → ...
```

Media graph 的 entity 名稱（從 driver 的 `snprintf` 直接來）：

| Entity | 來源 | Pads |
|---|---|---|
| `ov9282 X-0060`（`v4l2_i2c_subdev_set_name`） | `ov9282.c` | pad0 = SOURCE |
| `msm_csiphy<n>` | `camss-csiphy.c` `MSM_CSIPHY_NAME` | pad0 SINK, pad1 SOURCE |
| `msm_csid<m>` | `camss-csid.c` `MSM_CSID_NAME` | pad0 SINK, pad1.. SOURCE（每個 RDI 一個） |
| `msm_vfe<k>_rdi<x>` / `msm_vfe<k>_pix` | `camss-vfe.c` | pad0 SINK, pad1 SOURCE |
| `msm_vfe<k>_video<x>`（video node） | `camss-vfe.c` → `msm_video_register()` | – |

---

## 2. Kernel：Probe 階段（開機時）

### 2.1 OV9282 sensor driver — `drivers/media/i2c/ov9282.c`

`of_match`：`"ovti,ov9282"` / `"ovti,ov9281"` → `ov9282_probe()`

```
ov9282_probe()
 ├─ v4l2_i2c_subdev_init(&sd, client, &ov9282_subdev_ops)
 ├─ ov9282_parse_hw_config()
 │    ├─ devm_gpiod_get_optional("reset")          ← DT: reset-gpios
 │    ├─ devm_v4l2_sensor_clk_get()                ← DT: clocks (MCLK)
 │    ├─ clk_get_rate() == 24 MHz ?                ← OV9282_INCLK_RATE，不是 24MHz 直接 -EINVAL
 │    ├─ devm_regulator_bulk_get(avdd/dovdd/dvdd)
 │    └─ v4l2_fwnode_endpoint_alloc_parse(endpoint)
 │         ├─ data-lanes 必須 = 2                  ← OV9282_NUM_DATA_LANES
 │         ├─ link-frequencies 必須含 400000000    ← OV9282_LINK_FREQ
 │         └─ clock-noncontinuous → noncontinuous_clock
 ├─ devm_cci_regmap_init_i2c(client, 16)           ← 16-bit register address
 ├─ ov9282_power_on()
 │    ├─ regulator_bulk_enable()
 │    ├─ gpiod_set_value(reset, 1)                 ← 注意：DT 的 GPIO polarity 要配合
 │    ├─ clk_prepare_enable(inclk)
 │    └─ cci_write(MIPI_CTRL00, gated clock?)
 ├─ ov9282_detect()  : cci_read(0x300a) == 0x9281 ← 第一個要確認的點（I2C 通不通）
 ├─ cur_mode = 1280x800, code = MEDIA_BUS_FMT_Y10_1X10
 ├─ ov9282_init_controls()  (EXPOSURE, ANALOGUE_GAIN, VBLANK, HBLANK,
 │                           PIXEL_RATE, LINK_FREQ(RO), FLASH_*, …)
 ├─ media_entity_pads_init(1 pad, SOURCE), function = MEDIA_ENT_F_CAM_SENSOR
 ├─ v4l2_subdev_init_finalize()
 ├─ pm_runtime_enable()
 └─ v4l2_async_register_subdev_sensor(&sd)         ← 交給 async framework，等 CamSS 來接
```

支援的 mode（`supported_modes[]`）：1280x800、1280x720、640x400。
支援的 mbus code：`MEDIA_BUS_FMT_Y10_1X10`（預設）、`MEDIA_BUS_FMT_Y8_1X8`。
Pixel rate：10-bit = 400M×2×2/10 = 160 MP/s；8-bit = 200 MP/s。

### 2.2 CamSS — `drivers/media/platform/qcom/camss/camss.c`

```
camss_probe()                         (compatible 例：qcom,sc7280-camss / qcom,sm8250-camss …)
 ├─ camss_init_subdevices()           ← 依 SoC resources 建 csiphy[] / csid[] / vfe[]
 ├─ v4l2_device_register()
 ├─ v4l2_async_nf_init(&camss->notifier)
 ├─ camss_parse_ports()
 │    └─ for each endpoint in camss node "ports":
 │         ├─ v4l2_async_nf_add_fwnode_remote()      ← 透過 remote-endpoint 找到 ov9282
 │         └─ camss_parse_endpoint_node()
 │              ├─ bus_type 必須是 V4L2_MBUS_CSI2_DPHY（C-PHY 不支援）
 │              ├─ csiphy_id = endpoint 所在的 port 編號  ← port@N 決定用哪顆 CSIPHY！
 │              └─ clock-lanes / data-lanes / lane polarity → csiphy_lanes_cfg
 ├─ camss_register_entities()         ← 註冊 csiphy/csid/ispif/vfe subdev + video node
 ├─ camss_link_entities()             ← 建內部 link：csiphy→csid→(ispif)→vfe_rdi/pix
 ├─ media_device_register()
 └─ v4l2_async_nf_register()

（ov9282 和 camss 誰先 probe 都可以，兩邊都到齊後）
camss_subdev_notifier_bound()         ← subdev->host_priv = &camss->csiphy[port_id]
camss_subdev_notifier_complete()
 ├─ media_create_pad_link(ov9282:0 → msm_csiphyN:0, IMMUTABLE|ENABLED)
 └─ v4l2_device_register_subdev_nodes()   ← 產生 /dev/v4l-subdev*
```

**Probe 檢查點**

```sh
dmesg | grep -iE "ov9282|camss|csiphy|csid|vfe"
media-ctl -d /dev/media0 -p        # 看得到 "ov9282 ..." entity 且有 link 到 msm_csiphyN 才算 bind 成功
```

---

## 3. Kernel：格式協商（media-ctl 設定，streaming 前）

每一層 pad format 必須一致，否則 `STREAMON` 時 `video_check_format()` / link validate 會 `-EPIPE`。

| 層 | mbus / pix format | 程式位置 |
|---|---|---|
| ov9282 pad0 | `Y10_1X10` 或 `Y8_1X8`, 1280x800 | `ov9282_set_pad_format()` |
| csiphy pad0/1 | 同上（pass-through） | `camss-csiphy.c` |
| csid sink | `Y10_1X10` → DT `MIPI_CSI2_DT_RAW10`；`Y8_1X8` → `RAW8` | `camss-csid.c` `formats_*[]` |
| csid src | `Y10_1X10` 可轉成 `Y10_1X10` 或 `Y10_2X8_PADHI_LE`（`csid_src_pad_code()`） | `camss-csid.c` |
| vfe rdi | 見下表 | `camss-vfe.c` `formats_rdi_*[]` |
| video node | V4L2 pixfmt | `camss-video.c` `video_mbus_to_pix_mp()` |

VFE RDI mbus → V4L2 pixel format（重要，決定 GStreamer 吃不吃得下）：

| mbus code | V4L2 pixfmt | 哪些 VFE 表有 | 記憶體佈局 |
|---|---|---|---|
| `Y8_1X8` | `GREY` | **只有 `formats_rdi_845`**（SDM845/SC7280/SM8250/QCM2290… gen2 類） | 1 byte/pixel |
| `Y10_1X10` | `Y10P` | 8x16 / 8x96 / 845 | MIPI packed，4 pixel = 5 bytes |
| `Y10_2X8_PADHI_LE` | `Y10` | 8x96 / 845 | 16-bit LE，低 10 bit 有效 |

> ⚠️ MSM8916/MSM8939/MSM8953（`formats_rdi_8x16` + `csid_formats_4_1/4_7`）沒有 Y8，只能拿 `Y10P`。

---

## 4. Kernel：Streaming 階段（`VIDIOC_STREAMON` 之後）

```
v4l2src → ioctl(VIDIOC_REQBUFS / QBUF / STREAMON)
  vb2 → msm_video_vb2_q_ops
   ├─ video_queue_setup / video_buf_init / video_buf_prepare / video_buf_queue
   └─ video_start_streaming()                              camss-video.c
        ├─ video_device_pipeline_alloc_start()  ← media pipeline link_validate
        ├─ video_check_format()                 ← video node fmt 必須 == vfe src pad fmt
        └─ 從 video node 往上游走 sink pad → remote pad，對每個 subdev 呼叫 s_stream(1)：
             1. msm_vfeK_rdiX   vfe_set_stream()     → 設定 write master / RDI，enable IRQ
             2. msm_csidM       csid_set_stream()    → 設 VC/DT filter（RAW8/RAW10），enable
             3. msm_csiphyN     csiphy_set_stream()  → camss_get_link_freq() 讀 sensor LINK_FREQ，
                                                       算 settle count，lanes_enable()
             4. ov9282          v4l2_subdev_s_stream_helper → ov9282_enable_streams()
                                   ├─ pm_runtime_resume_and_get()   (power_on)
                                   ├─ cci_multi_reg_write(common_regs)
                                   ├─ bitdepth_regs (PLL_CTRL_0D / ANA_CORE_2: RAW8 vs RAW10)
                                   ├─ mode reg_list (1280x800 …)
                                   ├─ __v4l2_ctrl_handler_setup()   (寫 exposure/gain/vblank)
                                   └─ cci_write(0x0100, 0x01)       ← sensor 開始出 MIPI
  每一 frame：VFE write-master done IRQ → vfe_isr → vb2_buffer_done() → DQBUF 回到 v4l2src
```

注意啟動順序是 **由下游往上游**（VFE → CSID → CSIPHY → sensor），sensor 最後才 stream on，
所以接收端都 ready 才出資料。

---

## 5. Userspace：media-ctl 設定 + GStreamer

### 5.1 設 pipeline（以 CSIPHY0 / CSID0 / VFE0 RDI0、8-bit、1280x800 為例）

參考 `scripts/ov9282-camss-setup.sh`。核心指令：

```sh
MC="media-ctl -d /dev/media0"
SENSOR="$($MC -p | sed -n 's/.*entity [0-9]*: \(ov9282 [^ ]*\).*/\1/p' | head -n1)"
FMT=Y8_1X8/1280x800         # 或 Y10_1X10/1280x800

$MC --reset
$MC -l '"msm_csiphy0":1->"msm_csid0":0[1]'
$MC -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]'

$MC -V "\"$SENSOR\":0[fmt:$FMT field:none]"
$MC -V "\"msm_csiphy0\":0[fmt:$FMT field:none]"
$MC -V "\"msm_csid0\":0[fmt:$FMT field:none]"
$MC -V "\"msm_csid0\":1[fmt:$FMT field:none]"
$MC -V "\"msm_vfe0_rdi0\":0[fmt:$FMT field:none]"

VIDEO=$($MC -e msm_vfe0_video0)
```

先用 `v4l2-ctl` 確認 kernel 端 OK，**再**上 GStreamer：

```sh
v4l2-ctl -d $VIDEO --set-fmt-video=width=1280,height=800,pixelformat=GREY \
         --stream-mmap --stream-count=100 --stream-to=/tmp/ov9282.raw
```

### 5.2 GStreamer：`v4l2src`（`gst-plugins-good/sys/v4l2/gstv4l2object.c`）

v4l2src 的 format 對照表（`gst_v4l2_formats[]`）：

| V4L2 pixfmt | GStreamer caps | 結果 |
|---|---|---|
| `GREY` | `video/x-raw,format=GRAY8` | ✅ 直接可用 |
| `Y16` | `GRAY16_LE` | ✅（但 CamSS 不輸出 Y16） |
| `Y10` | `UNKNOWN`（只有 DMA-DRM `R10` 對應） | ⚠️ 一般 `video/x-raw` 協商不到 |
| `Y10P` | 表中**沒有** | ❌ v4l2src 不認 |

所以**要接 GStreamer，最省事是把整條 pipeline 設成 `Y8_1X8` → `GREY` → `GRAY8`**：

```sh
gst-launch-1.0 -v v4l2src device=$VIDEO io-mode=mmap ! \
  video/x-raw,format=GRAY8,width=1280,height=800 ! \
  videoconvert ! waylandsink          # 或 fakesink / kmssink / x264enc …
```

要 10-bit 的話選項：
- 自己寫一個 GStreamer element / appsrc，把 `Y10P` unpack 成 `GRAY16_LE`；
- 或改用 **libcamera**（`libcamerasrc`）：libcamera 的 simple pipeline handler 支援 `qcom-camss`，
  可搭配 software ISP 做 AE/unpack（需確認你的 libcamera 版本對 OV9282 / 該 SoC 的支援度）。

### 5.3 Exposure / gain（沒有 3A）

```sh
SUBDEV=$($MC -e "$SENSOR")
v4l2-ctl -d $SUBDEV -l                               # 列出 control
v4l2-ctl -d $SUBDEV -c exposure=800,analogue_gain=32
```

---

## 6. DT 範例（重點欄位，不是可直接用的完整 DTS）

```dts
&camss {
	status = "okay";
	ports {
		port@0 {                                 /* port 編號 = CSIPHY 編號 */
			csiphy0_ep: endpoint {
				clock-lanes = <7>;
				data-lanes = <0 1>;               /* 2 lane */
				remote-endpoint = <&ov9282_ep>;
			};
		};
	};
};

&cci0_i2c0 {   /* 或一般 i2c bus */
	camera@60 {
		compatible = "ovti,ov9282";
		reg = <0x60>;
		clocks = <&camcc CAM_CC_MCLK0_CLK>;
		assigned-clocks = <&camcc CAM_CC_MCLK0_CLK>;
		assigned-clock-rates = <24000000>;       /* 必須 24 MHz */
		reset-gpios = <&tlmm XX GPIO_ACTIVE_LOW>;
		avdd-supply = <...>; dovdd-supply = <...>; dvdd-supply = <...>;
		pinctrl-0 = <&cam_mclk0_default>;
		port {
			ov9282_ep: endpoint {
				data-lanes = <1 2>;
				link-frequencies = /bits/ 64 <400000000>;   /* 必須 400 MHz */
				remote-endpoint = <&csiphy0_ep>;
			};
		};
	};
};
```

並且**把 downstream camera-kernel 的 `cam_*` / `qcom,cam-*` node 全部 disable**（見第 0 節）。

---

## 7. Bring-up checklist / 除錯對照

| 症狀 | 看哪裡 | 常見原因 |
|---|---|---|
| `inclk frequency mismatch` | `ov9282_parse_hw_config()` | MCLK 不是 24 MHz |
| `number of CSI2 data lanes … not supported` / `-EINVAL` | 同上 | DT data-lanes ≠ 2，或沒有 400MHz link-frequencies |
| `chip id mismatch` / I2C NACK | `ov9282_detect()` | power sequence、reset 極性、I2C 位址、MCLK pinctrl |
| media graph 沒有 sensor→csiphy link | `camss_subdev_notifier_complete()` | `remote-endpoint` 沒對上、camss 沒 probe、async 沒完成 |
| `Unsupported bus type` | `camss_parse_endpoint_node()` | endpoint 被解析成 C-PHY / 沒設好 |
| `STREAMON` `-EPIPE` | `video_check_format()` / link validate | 各 pad format/size 不一致 |
| STREAMON 成功但 DQBUF 卡住 | VFE IRQ、CSID/CSIPHY 錯誤 IRQ | settle count（link freq）、lane 對應、VC/DT 不符、sensor 沒真的 stream（0x0100）|
| GStreamer `not-negotiated` | `gstv4l2object.c` format map | 用了 `Y10P`/`Y10`，改用 `Y8_1X8` → `GREY` |
| 兩套 camera driver probe 衝突 | dmesg clock/GDSC/ioremap error | upstream camss 與 downstream cam_* 同時啟用 |

有用的 debug：

```sh
echo 'file camss*.c +p; file ov9282.c +p' > /sys/kernel/debug/dynamic_debug/control
cat /proc/interrupts | grep -iE "csid|vfe|csiphy"    # 有沒有在跳
GST_DEBUG=v4l2*:6 gst-launch-1.0 ...
```

---

## 8. 參考

- Qualcomm Linux camera overview: https://docs.qualcomm.com/doc/80-70023-17/topic/camera-overview.html
- Upstream CamSS 文件: https://www.kernel.org/doc/html/latest/admin-guide/media/qcom_camss.html
  （v5.2 版: https://www.kernel.org/doc/html/v5.2/media/v4l-drivers/qcom_camss.html — 較舊，新 SoC 的 RDI/CSID gen2 不在內）
- `drivers/media/i2c/ov9282.c`
- `drivers/media/platform/qcom/camss/{camss.c,camss-csiphy.c,camss-csid.c,camss-vfe.c,camss-video.c}`
- `Documentation/devicetree/bindings/media/i2c/ovti,ov9282.yaml`
- GStreamer `subprojects/gst-plugins-good/sys/v4l2/gstv4l2object.c`
