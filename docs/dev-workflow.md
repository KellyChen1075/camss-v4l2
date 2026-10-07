# 開發環境：Windows 改 code → Ubuntu 編譯 → RB3 測試

```
 Windows 筆電 ──(VS Code Remote-SSH)──> Ubuntu 筆電 (~/qli-1.9, Yocto build)
                                            │ scp / ssh (scripts/rb3-deploy.sh)
                                            v
                                    RB3 (192.168.137.57, Wi-Fi)
```

原則：**source code 只放 Ubuntu 一份**，Windows 不存副本，避免兩邊不同步、CRLF、檔案權限問題。

## 1. 網路

`192.168.137.x` 是 Windows「行動熱點 / 網際網路連線共用」預設的網段，
所以 RB3 很可能是連在 Windows 筆電的熱點上。

- Ubuntu 也要能連到 `192.168.137.57`：讓 Ubuntu 也連 Windows 熱點，或兩台都接同一個 AP。
  在 Ubuntu 上先確認 `ping 192.168.137.57`。
- 連不到的話，可以從 Windows 跳板：`ssh -J <user>@<windows-ip> root@192.168.137.57`
  （Windows 要開 OpenSSH Server），或把檔案先拉到 Windows 再 scp 過去（較麻煩，不建議）。
- 建議在熱點設定裡把 RB3 的 IP 固定，或在 RB3 上設 static IP，不然重開機 IP 可能會變。

## 2. Windows：用 VS Code Remote-SSH 直接改 Ubuntu 上的 code

1. Ubuntu：`sudo apt install openssh-server`，記下 Ubuntu 的 IP（`ip a`）。
2. Windows：VS Code 裝 **Remote - SSH** extension → `Remote-SSH: Connect to Host` → `<user>@<ubuntu-ip>`。
3. 開資料夾 `~/qli-1.9/...`，編輯、終端機（build 指令）都在 Ubuntu 上執行。

`C:\Users\<you>\.ssh\config`：

```
Host qli
    HostName <ubuntu-ip>
    User <ubuntu-user>

Host rb3
    HostName 192.168.137.57
    User root
```

## 3. Ubuntu → RB3：免密碼 SSH

```sh
ssh-keygen -t ed25519            # 已有 key 可略過
ssh-copy-id root@192.168.137.57  # 之後 scp/ssh 不用再打密碼
```

（RB3 的 rootfs 可能是唯讀，push 前要 `mount -o remount,rw /`，`rb3-deploy.sh` 會自動做。）

## 4. 改 kernel driver（ov9282 / qcom-camss）的快速迴圈

先確認 kernel config：QLI 預設走 downstream camera stack，upstream 的
`CONFIG_VIDEO_QCOM_CAMSS`、`CONFIG_VIDEO_OV9282` 不一定有開。建議設成 `=m`（module），
才能只換 `.ko` 不必重刷整個 boot image：

```sh
# 在 RB3 上確認
zcat /proc/config.gz 2>/dev/null | grep -E "QCOM_CAMSS|OV9282"
ls /lib/modules/$(uname -r)/kernel/drivers/media/i2c/ | grep ov9282
```

Ubuntu 上用 devtool 把 kernel 原始碼拉出來改（recipe 名稱依你的 QLI 版本，先用
`bitbake-layers show-recipes | grep -i linux` 確認）：

```sh
cd ~/qli-1.9 && source setup-environment     # 依你平常的 build 環境設定方式
devtool modify <kernel-recipe>               # source 會出現在 build/workspace/sources/<kernel-recipe>
# ...改 drivers/media/i2c/ov9282.c 或 drivers/media/platform/qcom/camss/*
devtool build <kernel-recipe>
```

把 module 推上 RB3 並重新載入：

```sh
scripts/rb3-deploy.sh modules ~/qli-1.9/build-*/tmp-glibc/work
```

它會在 build 目錄下找最新的 `ov9282.ko`、`qcom-camss.ko`，複製到 RB3 的
`/lib/modules/$(uname -r)/updates/`，`depmod` 後 `rmmod` / `modprobe`，最後印出 dmesg。

> 注意：
> - `.ko` 必須和 RB3 上正在跑的 kernel 是同一份 source/config 編的（vermagic 要一致），
>   否則 `modprobe` 會失敗；改了 config 或換了 kernel 版本就要重刷 boot image。
> - **DT 的修改（camss / ov9282 node）不能只換 `.ko`**，要重新產生並燒錄 DTB / boot image。

## 5. 其他檔案（script、app、測試程式）推到指定資料夾

```sh
scripts/rb3-deploy.sh push /data/ov9282 scripts/ov9282-camss-setup.sh my_app
scripts/rb3-deploy.sh ssh                       # 進 RB3 shell
scripts/rb3-deploy.sh ssh 'sh /data/ov9282/ov9282-camss-setup.sh 8'
```

IP 或帳號不同時：`RB3_HOST=192.168.137.xx RB3_USER=root scripts/rb3-deploy.sh ...`
