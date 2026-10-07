# camss-v4l2
- [OV9282: kernel → CamSS → V4L2 → GStreamer trace](docs/ov9282-kernel-to-gstreamer-trace.md)
- [`scripts/ov9282-camss-setup.sh`](scripts/ov9282-camss-setup.sh): media-ctl setup for OV9282 on qcom-camss
- [Dev workflow: Windows edit → Ubuntu build → RB3 deploy](docs/dev-workflow.md)
- [`scripts/rb3-deploy.sh`](scripts/rb3-deploy.sh): push files / kernel modules to the RB3 over SSH
- [OV9282 → V4L2 + CamSS porting guide (QLI 1.9 / RB3 Gen2)](docs/ov9282-camss-porting-guide.md)
  - [`scripts/check-kernel-tree.sh`](scripts/check-kernel-tree.sh), [`kernel/ov9282-camss.cfg`](kernel/ov9282-camss.cfg), [`dts/qcs6490-rb3gen2-ov9282-camss.dtsi`](dts/qcs6490-rb3gen2-ov9282-camss.dtsi)
