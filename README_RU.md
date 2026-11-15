# AndOnMac 📱⚡️💻

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-blue?style=for-the-badge&logo=apple" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" />
  <img src="https://img.shields.io/github/v/release/V0val0x/AndOnMac?style=for-the-badge&color=brightgreen" />
</p>

[English Version](README.md) | **Русская версия**

> **Нативный open-source аналог Apple iPhone Mirroring для Android и Google Pixel на macOS.**

Бесплатное нативное приложение на SwiftUI и VideoToolbox для зеркалирования экрана Android-смартфона на 60 FPS, плавного управления с трекпада и клавиатуры, двустороннего переноса фото и файлов, общего буфера обмена и трансляции звука — без Electron и лишнего веса.

![Демо зеркалирования AndOnMac](./assets/demo-mirroring.gif)

### Демонстрация возможностей

| Трансляция 60 FPS и управление | Галерея и перенос фото на Mac (`Cmd+4`) | Общий буфер обмена (`macOS ↔ Android`) |
| :---: | :---: | :---: |
| ![Live Mirroring](./assets/demo-mirroring.gif) | ![Photo Transfer to Desktop](./assets/demo-photo-transfer.gif) | ![Universal Clipboard Sync](./assets/demo-clipboard-sync.gif) |

---

## ✨ Ключевые возможности

* 📱 **Программные векторные рамки и Ambilight (`DeviceFrameRenderer` + `AmbilightEngine`)**: точное определение модели и вендора устройства (`ro.product.model` / `ro.product.vendor`), векторные безели, калиброванный вырез камеры и адаптивное фоновое свечение через Metal `CoreImage` (`CIAreaAverage`) для **Google Pixel 11 Pro / 11 / 10a / 8 / 9 / 10**, **Samsung Galaxy S24/S25 и Ultra**, **Xiaomi**, **Nothing Phone (2)**, **OnePlus 12**, а также универсальная рамка **Pro Display** и вкладка настроек **Оформление**.
* 🪟 **Нативный macOS Vibrancy и пружинные анимации**: полупрозрачные панели (`NSVisualEffectView` / `.ultraThinMaterial`), поповер в строке меню и плавный ресайз по пресетам и при повороте экрана.
* ⚡️ **60 FPS аппаратное декодирование (`VideoToolbox`)**: потоковая передача H.264 напрямую через `VTDecompressionSession` во встроенный `NSView` без отдельного SDL-окна в Dock.
* 🖱 **Плавные жесты трекпада и смартфона**: инерция 1:1 для скролла, зума (pinch-to-zoom) и навигационных жестов Android — свайп с краёв (Назад), свайп снизу вверх (Домой / Недавние) и шторка уведомлений.
* 📋 **Универсальный буфер обмена (`macOS ↔ Android`)**: мгновенная двусторонняя синхронизация текста и вставка (`Cmd+C` на Mac → `Cmd+V` на телефоне и обратно).
* 🖼 **Полноценная медиатека и перенос файлов (`Cmd+4`)**: просмотр всей галереи (Камера, Скриншоты, Загрузки, Видео), перетаскивание фото прямо на рабочий стол Mac или в приложения, а также загрузка файлов с Mac в `/sdcard/Download/`.
* ⌨️ **Синхронизация раскладки клавиатуры и кириллица**: автоматическое переключение раскладки Android вслед за macOS и поддержка ввода кириллицы, плюс отправка сообщений по `Enter` (`Shift+Return` для переноса строки).
* 🔊 **Передача звука и уведомлений**: системный звук смартфона играет через динамики Mac, а пуши приходят в Центр уведомлений macOS.
* 🌍 **Мультиязычный интерфейс (RU / EN)**: автоматически выбирает язык системы с возможностью переключения в настройках.
* 🔌 **USB и Wi-Fi (Bonjour mDNS)**: мгновенный старт по кабелю Type-C или беспроводное сопряжение по 6-значному PIN-коду Android 11+.

---

## 🚀 Установка и быстрый старт

### Способ 1: Готовый установщик (Рекомендуется)
1. Скачайте последний релиз [**AndOnMac.dmg (GitHub Releases)**](https://github.com/V0val0x/AndOnMac/releases).
2. Откройте образ и перетащите **AndOnMac.app** в папку `Applications` («Программы»).
3. Подключите Android по USB-C (с включённой **Отладкой по USB**) или по Wi-Fi (*Параметры разработчика → Беспроводная отладка*).

### Способ 2: Homebrew Cask
```bash
brew install --cask ./packaging/Casks/andonmac.rb
```

### Способ 3: Сборка из исходников (macOS 14+, Swift 5.9+ / 6.x)
```bash
# 1. Установите зависимости (автоматически упаковываются в .app)
brew install scrcpy android-platform-tools

# 2. Запустите тесты
swift test

# 3. Соберите dist/AndOnMac.app и dist/AndOnMac.dmg
chmod +x scripts/*.sh
./scripts/build_app.sh && ./scripts/create_dmg.sh
```

---

## ⌨️ Горячие клавиши

| Сочетание клавиш | Действие |
| :--- | :--- |
| `Cmd + 1` / Свайп вверх снизу | Домашний экран (`KEYCODE_HOME`) |
| `Cmd + 2` / Высокий свайп снизу | Недавние приложения (`KEYCODE_APP_SWITCH`) |
| `Cmd + 3` | Шторка уведомлений (`KEYCODE_NOTIFICATION`) |
| `Cmd + 4` | Открыть / скрыть медиатеку и перенос фото |
| `Cmd + Backspace` / `Esc` / ПКМ | Назад (Back) |
| `Cmd + P` | Блокировка / Включение экрана |
| `Cmd + 0` / `Cmd + +` / `Cmd + -` | Масштаб окна (100% / 125% / 75%) |
| `Cmd + Shift + R` | Сброс ADB и переподключение USB |
| `Cmd + W` | Остановить трансляцию / Закрыть окно |

---

## 🛠 Архитектура и стек

* **Frontend**: Swift 6.0, SwiftUI, AppKit (macOS 14.0+).
* **Видео и сеть**: Apple `VideoToolbox`, `Network.framework` (Bonjour mDNS / NWBrowser, TCP).
* **Ядро стриминга**: [scrcpy](https://github.com/Genymobile/scrcpy) (H.264 / Opus decoding).
* **Сборка**: GitHub Actions CI с автоматической проверкой и сборкой DMG.

---

## 📄 Лицензия

MIT License © 2026 Zaitcev Kirill.  
Ядро зеркалирования использует открытые компоненты Genymobile scrcpy (Apache 2.0).
