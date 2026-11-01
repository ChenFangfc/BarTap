<div align="center">

<img src="assets/logo/bartap-icon.svg" width="112" alt="BarTap icon">

# BarTap

**A tidy menu bar and live system stats for macOS, in one small app that never touches your mouse.**

<a href="https://github.com/ChenFangfc/BarTap/releases/latest/download/BarTap.dmg"><img src="https://img.shields.io/badge/download-BarTap.dmg-2B2B2E?style=flat-square&logo=apple&logoColor=white" alt="Download BarTap.dmg"></a>
<img src="https://img.shields.io/badge/macOS-13%2B-555?style=flat-square" alt="macOS 13 or later">
<img src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-555?style=flat-square" alt="Universal binary">
<a href="README.zh-CN.md"><img src="https://img.shields.io/badge/README-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-d9d9d9?style=flat-square" alt="简体中文 README"></a>

**[Download](https://github.com/ChenFangfc/BarTap/releases/latest/download/BarTap.dmg)** · [Features](#features) · [Install](#install) · [Why it can't twitch](#why-it-cant-twitch) · [Build](#build-from-source)

<br>

<a href="https://chenfangfc.github.io/BarTap/media/bartap-film-en.mp4"><img src="docs/media/bartap-preview.webp" width="100%" alt="BarTap in 30 seconds: a crowded menu bar, icons tucked behind one divider, live system stats"></a>

<sub><a href="https://chenfangfc.github.io/BarTap/media/bartap-film-en.mp4"><b>▶ Watch with sound (0:32)</b></a> · <a href="https://chenfangfc.github.io/BarTap/media/bartap-film-zh.mp4"><b>▶ 中文版</b></a></sub>

</div>

---

BarTap hides the menu bar icons you don't need behind one divider, and keeps CPU, GPU, memory, disk, network, sensors, battery and a clock live in the bar. It does this without fake clicks, event taps or cursor warps, so the screen never twitches and the mouse stays yours.

## Features

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/bar-dark.webp">
  <img src="docs/media/bar-light.webp" width="100%" alt="BarTap's toggle and stats items: CPU, GPU, memory, disk, network, sensors, battery and time">
</picture>

**Organize**
- Hide icons behind the toggle. An optional ‖ section keeps some hidden for good.
- Reveal them with a click, hover, scroll or hotkey (⌃⌥⌘B). They re-hide on their own.
- Search any menu bar icon (⌃⌥⌘F). A shelf below the notch holds icons that don't fit.
- Rules reveal icons on a large display, in chosen apps, on low battery or when you're offline.
- Clean menu bar for screenshots, tighter icon spacing, Keep Awake and a color picker.

**Monitor**
- Eight modules with classic graph, pie, percentage and rate readouts, refreshed every second.
- Dropdowns with history graphs, per-core load, top processes, Wi-Fi details, daily and monthly data use, temperatures, fans, power, battery health and Bluetooth device batteries.
- Alerts for a lost connection, a full battery, high CPU or heat, memory pressure, a low disk and a low battery.
- World clocks, a calendar, °F and bits. Combine all stats into one item to save space by the notch.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/panels-dark.webp">
  <img src="docs/media/panels-light.webp" width="100%" alt="The CPU, network and sensors dropdowns">
</picture>

## Install

1. [Download BarTap.dmg](https://github.com/ChenFangfc/BarTap/releases/latest/download/BarTap.dmg), open it and drag BarTap to Applications.
2. BarTap is ad-hoc signed, not notarized. If macOS blocks the first launch, open **System Settings › Privacy & Security** and click **Open Anyway**. You only do this once.
3. Hold ⌘ and drag icons left of the │ divider to hide them. Turn on stats in **Settings › Stats**.

Hiding needs no permission. Accessibility access is optional: it enables search, the shelf and the layout list. Quit any other menu bar manager first.

## Why it can't twitch

Organizers that move icons for you do it by posting synthetic ⌘-drags, sometimes while freezing or warping the cursor. When macOS lags, those events land in the wrong place: the screen jumps and the mouse fights back.

BarTap only changes the length of its own divider items. It never posts input events, installs event taps or moves the pointer, and [`scripts/build.sh`](scripts/build.sh) fails the build if the binary links any API that could. You arrange icons yourself with ⌘-drag, the way macOS intends. Quit BarTap and every icon comes straight back.

## Light by design

Idle, BarTap uses about **0.02% CPU** and **~40 MB** of memory. Four live stats refreshed every second add about **1% CPU**. Unchanged readouts are never redrawn, and details and process lists are sampled only while a dropdown is open. There is no daemon and no root helper, and BarTap makes no network requests unless you turn on the public IP lookup.

<sub>Measured on a MacBook Pro (M2 Max) running macOS 26.</sub>

## Build from source

You need macOS 13+ and the Xcode Command Line Tools (Swift 5.10+).

```bash
git clone https://github.com/ChenFangfc/BarTap.git && cd BarTap
scripts/build.sh    # tests, universal build, input-API guard -> dist/BarTap.app and the DMG
```

The film is code too. `promo/build.sh` renders it from BarTap's own drawing code and sample data.
