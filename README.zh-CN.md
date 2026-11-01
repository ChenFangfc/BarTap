<div align="center">

<img src="assets/logo/bartap-icon.svg" width="112" alt="BarTap 图标">

# BarTap

**整理菜单栏、实时系统监控、AI 编程用量，一个轻巧的 macOS 小工具，而且从不碰你的鼠标。**

<a href="https://github.com/ChenFangfc/BarTap/releases/latest/download/BarTap.dmg"><img src="https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-BarTap.dmg-2B2B2E?style=flat-square&logo=apple&logoColor=white" alt="下载 BarTap.dmg"></a>
<img src="https://img.shields.io/badge/macOS-13%2B-555?style=flat-square" alt="macOS 13 及以上">
<img src="https://img.shields.io/badge/Apple%20%E8%8A%AF%E7%89%87%20%2B%20Intel-%E9%80%9A%E7%94%A8-555?style=flat-square" alt="通用二进制">
<a href="README.md"><img src="https://img.shields.io/badge/README-English-d9d9d9?style=flat-square" alt="English README"></a>

**[下载](https://github.com/ChenFangfc/BarTap/releases/latest/download/BarTap.dmg)** · [功能](#功能) · [安装](#安装) · [为什么不会抽动](#为什么不会抽动) · [从源码构建](#从源码构建)

<br>

<a href="https://chenfangfc.github.io/BarTap/media/bartap-film-zh.mp4"><img src="docs/media/bartap-preview-zh.webp" width="100%" alt="37 秒看懂 BarTap：塞满的菜单栏、一条分隔线收起图标、实时系统监控和 AI 用量"></a>

<sub><a href="https://chenfangfc.github.io/BarTap/media/bartap-film-zh.mp4"><b>▶ 带声音观看（0:37）</b></a> · <a href="https://chenfangfc.github.io/BarTap/media/bartap-film-en.mp4"><b>▶ English</b></a></sub>

</div>

---

BarTap 把用不上的菜单栏图标收到一条分隔线后面，在菜单栏里实时显示 CPU、GPU、内存、磁盘、网络、传感器、电池和时间，还能显示你的 AI 编程工具用了多少。它不伪造点击、不拦截事件、不移动指针，所以屏幕不会抽动，鼠标始终归你控制。

## 功能

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/bar-dark.webp">
  <img src="docs/media/bar-light.webp" width="100%" alt="BarTap 开关与各项监控：CPU、GPU、内存、磁盘、网络、传感器、电池、AI 用量、时间">
</picture>

**整理**
- 把图标收到开关左侧；可选的 ‖ 区域让部分图标一直隐藏。
- 点按、悬停、滚动或快捷键（⌃⌥⌘B）即可显示，用完自动收起。
- 刘海屏 Mac 上，点一下可以弹出图标架：像 Bartender 那样的下拉栏，一排列出被隐藏的图标（可显示真实图标），点哪个就打开哪个的菜单。
- 搜索任意菜单栏图标（⌃⌥⌘F）。
- 自动规则：接大屏、切到指定应用、电量低或断网时自动显示。
- 一键干净菜单栏（截图、演示用）、更紧凑的图标间距、防休眠、取色器。

**监控**
- 八个模块，每秒刷新。每一项都能用元素自由组合、自由排序（曲线、柱条、饼图、圆环、百分比、U:/F:、R:/W:、↑↓、标签……），也可以直接选预设；各项在菜单栏里的先后顺序也能调。
- 下拉菜单里有历史曲线、每核负载、占用最高的进程、Wi-Fi 详情、每日/每月流量、温度、风扇、功耗、电池健康度和蓝牙设备电量。
- 提醒：断网/恢复、充满电、CPU 占用或温度过高、内存压力、磁盘将满、电量低。
- 世界时钟和日历，支持 °F 和 bit 单位；还能把所有监控合并成一个图标，给刘海旁边省空间。

**AI 用量**
- 从本机日志统计 Claude Code、Codex、Gemini CLI、OpenCode、Kilo Code、Qwen Code、Kimi Code 的 token 和费用。不要 API 密钥，不用登录，不上传任何东西。
- 今天、本周、本月、本季度、今年；可以统计全部、其中几个或单个工具，显示总和，或每个工具并排显示。
- 费用 = 这些 token 按 API 价格要花多少钱（LiteLLM 公开价目表），订阅套餐也能看出用量折合多少钱。
- 套餐额度按 Claude Code 和 Codex 自己的记录显示：5 小时和每周额度，可选显示已用或剩余，附重置时间。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/layouts-dark.webp">
  <img src="docs/media/layouts-light.webp" width="100%" alt="部分样式：CPU 曲线、圆环、柱条、每核；内存 U/F、饼图；磁盘 R/W、饼图；网速、温度风扇、电池；AI token 与费用、套餐额度、每个工具单独显示">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/panels-dark.webp">
  <img src="docs/media/panels-light.webp" width="100%" alt="CPU、网络、AI 用量下拉菜单">
</picture>

## 安装

1. [下载 BarTap.dmg](https://github.com/ChenFangfc/BarTap/releases/latest/download/BarTap.dmg)，打开后把 BarTap 拖进「应用程序」。
2. BarTap 没有经过 Apple 公证。第一次打开如果被拦，去 **系统设置 › 隐私与安全性**，点 **仍要打开**，只需一次。
3. 按住 ⌘ 把图标拖到 │ 分隔线左边就会隐藏。系统监控和 AI 用量在 **设置 › 系统监控** 里打开。

隐藏图标和 AI 用量都不需要任何权限。另有两个可选权限：**辅助功能**用于图标架、搜索和布局列表；**录屏**让图标架显示真实图标。升级后两项权限都会保留。请先退出其他菜单栏管理工具。

## 为什么不会抽动

替你挪图标的整理工具，靠的是发送模拟的 ⌘ 拖动，有时还会冻结或瞬移指针。系统一卡，这些事件就落错地方：屏幕跳动，鼠标也不听使唤。

BarTap 只改变自己分隔线的长度。它从不发送输入事件、不安装事件监听、不移动指针；只要二进制里链接了任何能做这些事的 API，[`scripts/build.sh`](scripts/build.sh) 就会让构建失败。图标由你自己用 ⌘ 拖动排列，这是 macOS 本来的方式。退出 BarTap，所有图标立刻恢复原样。

## 轻量

空闲时 BarTap 大约只占 **0.02% CPU** 和 **约 40 MB** 内存；再开四项每秒刷新的监控，CPU 多 **1–3%**，取决于有几块屏幕在显示菜单栏（macOS 会在每块屏幕上重绘有变化的那一项）。数值没变就不重绘，详情和进程列表只在下拉菜单打开时才采样。AI 用量只读取工具新写入的那几行，写入后几秒内更新；第一次读取很长的历史需要几秒（7 GB 日志约 11 秒）。没有后台守护进程，也没有 root 助手。BarTap 只在两种情况下联网：你打开了「显示公网 IP」；或开着 AI 用量时每周下载一次公开的模型价目表（可以关掉）。

<sub>测试机：MacBook Pro（M2 Max），macOS 26。</sub>

## 从源码构建

需要 macOS 13+ 和 Xcode Command Line Tools（Swift 5.10+）。

```bash
git clone https://github.com/ChenFangfc/BarTap.git && cd BarTap
scripts/build.sh    # 单元测试、通用二进制、输入 API 检查 -> dist/BarTap.app 和 DMG
```

宣传片也是代码：`promo/build.sh` 用 BarTap 自己的绘制代码和示例数据渲染出来。
