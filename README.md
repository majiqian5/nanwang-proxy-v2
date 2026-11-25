# DSH Engine · GitHub Actions 构建（真 arm64e）

## 为什么要在 Mac 上编

本机是 Linux，clang/ld64.lld 编出来的 `arm64e` 切片**没有指针认证代码**（`pacibsp` 计数 0、无 `__AUTH` 段），只是把 CPU 子类型补成 `0x80000002` 而已。Theos 官方文档写明：往 arm64e 平台进程（SpringBoard）注入，arm64 二进制**没有向后兼容**。所以这类"Linux 编的插件在 A12 以上机器上不注入、换 Mac 编同一份源码就好"的现象才会大面积出现。

这个仓库用 GitHub 的 **macos-15 runner**（自带 Xcode 16 的 Apple clang + ld64；`macos-14` 已下线）编译，产出的是真正的 arm64e；同时用 `GOOS=ios` + cgo 把 `dsh` 命令行编成**真正的 iOS 二进制**（不再是 macOS 平台补丁货）。

## 三步出包

> 注意：GitHub 已经下线 `macos-14`，workflow 里用的是 `macos-15`；如果哪天也下线了，把 `runs-on:` 改成 `macos-latest` 即可。

1. 在 GitHub 新建一个仓库（私有公开都行）。
2. 把这个压缩包解压后的**全部内容**（含隐藏目录 `.github`）推上去：

```sh
git init
git add -A
git commit -m "dsh build"
git branch -M main
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

手机端直接用 GitHub 网页版的 "Add file → Upload files" 拖整个文件夹也行，注意别漏 `.github/workflows/build.yml`。

3. 进仓库的 **Actions** 标签，`build-deb` 会自动跑（约 5–8 分钟）。跑完点进去，在页面底部 **Artifacts** 下载 `dsh-deb`，里面就是 `com.zaka.dsh_x.x.x_iphoneos-arm64.deb`。

## 装完怎么验

```sh
dpkg -i com.zaka.dsh_*_iphoneos-arm64.deb
killall -9 SpringBoard
```

桌面回来后重进终端：

```sh
dsh-check          # 看“注入信标 load.log”
dsh status         # 这次应该是真正能跑的 iOS 二进制
```

## 仓库结构

- `src/` —— 1.0.2 起的所有崩溃修复 + 熔断 + 注入信标（`DSHHooks.m` 里写 `load.log`）
- `tools/dsh-go/` —— 控制面 CLI 源码
- `layout/` —— rootless 布局（Theos 打包时自动加 `/var/jb` 前缀）
- `DSH.plist` —— ElleKit 过滤器（当前用 `Classes = ("SpringBoard")`）
- `control` / `layout/DEBIAN/postinst` —— 包信息与安装脚本
- `scripts/build-mac.sh` —— 直接用 xcrun clang/lipo 编双架构 + `GOOS=ios` 编 CLI + 打 deb（不用 Theos，runner 上依赖最少）
- `.github/workflows/build.yml` —— 构建流程（`runs-on: macos-15`）

## 如果还想换回 Bundles 过滤

`DSH.plist` 改成：

```xml
<key>Filter</key>
<dict>
  <key>Bundles</key>
  <array><string>com.apple.springboard</string></array>
</dict>
```

改完 push 一次就会重新出包，方便对照哪种过滤在你的设备上生效。
