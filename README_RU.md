# AndOnMac 📱⚡️💻

Нативное macOS-приложение на SwiftUI, VideoToolbox и Metal для зеркалирования экрана Android-смартфона до **120 FPS (ProMotion)**, плавного управления и обмена файлами — без Electron и лишнего веса.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+ / Android](https://img.shields.io/badge/Platform-macOS%2014%2B%20%7C%20Android-blue.svg)](https://github.com/V0val0x/AndOnMac)
[![GitHub Release](https://img.shields.io/github/v/release/V0val0x/AndOnMac?color=brightgreen)](https://github.com/V0val0x/AndOnMac/releases)
[![CI](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20this%20project-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

[English Version](README.md) | **Русская версия** · [Подробное руководство и архитектура](docs/FEATURES_RU.md)

![Демо зеркалирования AndOnMac](./assets/demo-mirroring.gif)

### Демонстрация возможностей

| Персистентный A* символьный UI-роутер ([DroidPath](https://github.com/V0val0x/DroidPath)) |
| :---: |
| ![Persistent A* Symbolic UI Router](./assets/demo-droidpath-presentation.gif) |

| Трансляция до 120 FPS и жесты | Рамки устройств и Ambilight | Галерея и перенос фото (`Cmd+4`) | Общий буфер (`macOS ↔ Android`) |
| :---: | :---: | :---: | :---: |
| ![Live Mirroring](./assets/demo-mirroring.gif) | ![Device Frames & Ambilight](./assets/demo-frames-ambilight.gif) | ![Photo Transfer to Desktop](./assets/demo-photo-transfer.gif) | ![Universal Clipboard Sync](./assets/demo-clipboard-sync.gif) |

---

## Ключевые возможности

- **Движок 120Hz ProMotion:** аппаратное ускорение `HEVC` (с автопереходом на `H.264`), zero-copy рендеринг через `CAMetalLayer` + `120Hz CADisplayLink`, адаптивный битрейт (ABR) и Performance HUD.
- **Векторные рамки, Ambilight и macOS Vibrancy:** точное определение устройства и калиброванные вырезы камер (**Pixel 11 Pro / 11 / 10a / 8–10**, **Galaxy S24/S25 и Ultra**, **Nothing Phone (2)**, **OnePlus 12**, универсальный **Pro Display**), мягкий CoreImage Ambilight, жесты трекпада по 4 краям и нижней полоске, полупрозрачные панели `.ultraThinMaterial` и вкладка **Оформление** в настройках.
- **Мгновенное подключение и обход изоляции:** USB-C, QR-сопряжение / Bonjour Wi-Fi для Android 11+, тихий переход USB → Wi-Fi и переключение на **Direct Hotspot / Bluetooth PAN** в 1 клик при изоляции роутера.
- **Отдельные окна приложений и Menu Bar:** поиск и запуск любых приложений Android (включая YouTube, Chrome и системные) в отдельном окне macOS (`Запуск приложения Android`) и быстрые переключатели в строке меню.
- **Медиатека (`Cmd+4`), файловый менеджер (`Cmd+5`) и Continuity:** двусторонний drag-and-drop фото, APK и файлов, плюс фоновая синхронизация текста и скриншотов на Android.
- **Персистентный A* UI-роутер и 120Hz Agentic HUD ([DroidPath](https://github.com/V0val0x/DroidPath)):** headless Kotlin single-DEX демон `android-daemon` стримит живое дерево Shadow DOM по ADB TCP (`:27189`) в локальный **Spatial Graph** (`shadow_graph.json`) с канонизацией динамических часов/дат, пассивным обучением на ручных кликах/свайпах, самовосстановлением демона и инструментом `android_navigate_to_node` с 120Hz прицелом, пунктирной траекторией свайпа и пошаговым HUD-индикатором (`0` промежуточных вызовов LLM).
- **Локальный ИИ, Vision OCR, Recall и Visual-to-MCP (`Cmd+Shift+M`):** распознавание текста через Neural Engine (`Cmd+Shift+X`), поиск по истории экрана **Recall** (`Cmd+Shift+F`, SQLite FTS5), встроенный **MCP-сервер** и запись самовосстанавливающихся макросов с **MCP Tool Hub**.

> Подробное описание настройки MCP, модели безопасности, всех горячих клавиш и архитектуры: [**docs/FEATURES_RU.md**](docs/FEATURES_RU.md).

---

## 🚀 Установка и быстрый старт

### Способ 1: Homebrew Tap (Рекомендуется — без проблем с Gatekeeper)
```bash
brew install --cask V0val0x/andonmac/andonmac
```
Обновление: `brew upgrade --cask andonmac`.

### Способ 2: Готовый установщик `.dmg` (GitHub Releases)
1. Скачайте последний [**AndOnMac.dmg (GitHub Releases)**](https://github.com/V0val0x/AndOnMac/releases).
2. Перетащите **AndOnMac.app** в `/Applications` и снимите карантин один раз (проект распространяется бесплатно без платной подписи Apple Developer ID):
   ```bash
   xattr -cr /Applications/AndOnMac.app
   ```
   *(Либо через **Системные настройки → Конфиденциальность и безопасность → Всё равно открыть**.)*
3. Подключите Android по USB-C (**Отладка по USB**) или по Wi-Fi (*Параметры разработчика → Беспроводная отладка*).

### Способ 3: Сборка из исходников (macOS 14+, Swift 5.9+ / 6.x)
```bash
brew install scrcpy android-platform-tools
swift test
chmod +x scripts/*.sh && ./scripts/create_dmg.sh
```

---

## Основные горячие клавиши

| Сочетание | Действие |
| :--- | :--- |
| `Cmd + 1` / `Cmd + 2` / `Cmd + 3` | Домой / Недавние / Шторка уведомлений |
| `Cmd + 4` / `Cmd + 5` | Галерея и перенос фото / Файловый менеджер |
| `Cmd + Shift + X` / `Cmd + Shift + F` | Apple Vision OCR / Поиск по истории экрана (Recall) |
| `Cmd + Shift + R` / `Cmd + W` | Сброс ADB и USB / Остановить трансляцию |

Полная таблица горячих клавиш и жестов — в [**docs/FEATURES_RU.md**](docs/FEATURES_RU.md#горячие-клавиши-и-жесты).

---

## Модульная open-source экосистема (отдельные Swift-пакеты)

Ключевые движки AndOnMac выделены в самостоятельные **MIT Swift 5.9+ пакеты** (`macOS 14+`), чтобы разработчики могли легко встраивать их в свои проекты:

| Репозиторий | Назначение | Подключение (SPM / CLI) |
| :--- | :--- | :--- |
| [**DroidPath**](https://github.com/V0val0x/DroidPath) | Headless Kotlin **Shadow DOM демон** (`android-daemon.jar`), персистентный **Spatial Graph** + **A* UI-роутер**, самовосстановление ADB и автономный CLI-сервер `droidpath-mcp` | `.package(url: "https://github.com/V0val0x/DroidPath.git", from: "1.0.0")` |
| [**MetalScrcpyKit**](https://github.com/V0val0x/MetalScrcpyKit) | Zero-copy **120Hz ProMotion** декодер `VideoToolbox` (H.264/HEVC), Metal-рендерер на `CAMetalLayer` + `CVMetalTextureCache`, ABR `PerformanceEngine` и `ProcessLifecycleManager` | `.package(url: "https://github.com/V0val0x/MetalScrcpyKit.git", from: "1.0.0")` |
| [**ADBConnectKit**](https://github.com/V0val0x/ADBConnectKit) | Swift SDK для **ADB** без внешних зависимостей: **USB**, **Wi-Fi QR-сопряжение**, Bonjour и обход изоляции роутера (**Direct Hotspot / Bluetooth PAN**) | `.package(url: "https://github.com/V0val0x/ADBConnectKit.git", from: "1.0.0")` |
| [**AndroidMCPKit**](https://github.com/V0val0x/AndroidMCPKit) | Встроенный **MCP-сервер** (`stdio` и HTTP/SSE), Visual-to-MCP `{{parameter}}`-макросы с 3-уровневым Self-Healing через Vision OCR и готовый CLI `android-mcp` | `.package(url: "https://github.com/V0val0x/AndroidMCPKit.git", from: "1.0.0")` |
| [**VisionScreenRecallKit**](https://github.com/V0val0x/VisionScreenRecallKit) | Локальный **Apple Silicon Vision OCR**, детектор изменений кадра, **SQLite FTS5** память экрана («Recall») и готовые SwiftUI-оверлеи | `.package(url: "https://github.com/V0val0x/VisionScreenRecallKit.git", from: "1.0.0")` |

---

## Поддержка и лицензия

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Leave%20a%20tip-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

MIT License © 2026 Kirill Zaitsev. См. [LICENSE](./LICENSE).

Использует компоненты [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) и **Android Platform Tools (`adb`)** под лицензией Apache 2.0 ([THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)).
