# Readboy C13 (MSM8996) mainline kernel - GitHub Actions build

这个仓库用 GitHub Actions 云编译读书郎 C13 的主线内核。

- 内核源：msm8996-mainline `v6.19.5-msm8996`（postmarketOS 使用的版本）
- 配置：postmarketOS 官方 msm8996 配置（`config/`）
- 板级补丁：`patches/c13-port.patch`（C13 设备树、ILI9881D 面板驱动、编译配置）
- 产物：`boot-c13.img`（可 fastboot/TWRP 刷入 boot 分区）

## 使用方法

1. 在 GitHub 上创建仓库（Public/Private 都行），把本目录内容推上去：

```bash
cd c13-kernel-gh
git init
git add -A
git commit -m "Readboy C13 kernel build"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

2. 推送后 Actions 自动编译（也可手动：Actions 页面 → Run workflow）。
3. 编译完成（约 1-2 小时）后，在 Actions 页面下载 `c13-boot` 产物，里面有 `boot-c13.img`。

## 刷机

```bash
# 进 fastboot 或 TWRP 后：
fastboot flash boot boot-c13.img
# 或 TWRP:
adb push boot-c13.img /tmp/ && adb shell dd if=/tmp/boot-c13.img of=/dev/block/bootdevice/by-name/boot
```

## 修改内核后重新编译

直接改 `patches/c13-port.patch` 或重新生成：

```bash
# 在本地内核树（c13-port 分支）里：
git diff v6.19.5-msm8996 > patches/c13-port.patch
git commit -am "update patch" && git push
```

## 本地编译（可选）

```bash
sudo apt install gcc-aarch64-linux-gnu android-tools-mkbootimg
git clone --depth 1 --branch v6.19.5-msm8996 https://gitlab.com/msm8996-mainline/linux.git
cd linux && git apply ../patches/c13-port.patch
cp ../config/config-postmarketos-qcom-msm8996.aarch64 .config
make ARCH=arm64 olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image.gz dtbs
```
