# PikminSend

一款結合桌寵互動與 [LocalSend v2](https://github.com/localsend/protocol) 協議的 macOS 輕量級區域網路 / Tailscale 傳檔工具。

| 待機召喚（雙擊 `Shift`） | 裝入檔案合力搬運 | 接收端左下角探頭確認 |
| :---: | :---: | :---: |
| ![待機動畫](docs/demo_idle.gif) | ![搬運動畫](docs/demo_carry.gif) | ![探頭接收](docs/demo_peek.gif) |

## 功能特色

- **選單列常駐 & 雙擊 `Shift` 喚醒**：平時隱身於 macOS 頂部選單列（不佔 Dock），連按兩下 `Shift` 即可在螢幕左下角召喚桌寵（會自動過濾打字大寫誤觸）。
- **完全相容 LocalSend v2 協議**：支援區網 UDP Multicast 自動發現（`224.0.0.167:53317`），可與 iOS / Windows / Android 原版 LocalSend 互傳檔案、剪貼板與純文字。
- **Tailscale 跨區自動掃描**：自動呼叫本機 Tailscale CLI 解析在線節點（`100.x.y.z`），無需手動輸入 IP 即可在巴士路牌中選取遠端電腦。
- **桌寵互動流程**：
  - 待機時三隻皮克敏正面站立陪伴，右鍵選單或直接拖曳檔案即可裝入野餐籃（裝入後切換為環狀合力搬運與跳動文件動畫）。
  - 點擊黃色巴士路牌選擇傳送對象，送達後整隊往左側退場。
  - 接收端收到傳輸請求時，螢幕左下角會有紅色皮克敏探頭張望，點擊氣泡即可確認接收（文字自動複製進剪貼板，檔案存入 `~/Downloads/`）。

## 本機編譯與打包

環境需求：macOS 14+、Swift 5.9+（Command Line Tools 或 Xcode）。

```bash
./scripts/build_app.sh
open build/PikminSend.app
```

首次執行時請依提示授予**「輔助使用（Accessibility）」**權限，以啟用全域雙擊 `Shift` 喚醒功能。

## 目錄結構

- `Sources/PikminSend/`：Swift 應用程式原始碼（選單列、熱鍵監聽、LocalSend 伺服器/客戶端、Tailscale 發現、桌寵視窗）
- `Resources/`：打包完成的透明 APNG 動畫素材（`pikmin_idle.png`、`pikmin_carry.png`、`pikmin_peek_idle.png`、`pikmin_peek_wave.png`）
- `docs/`：README 展示用 GIF 動圖
- `scripts/`：Blender 自動算圖腳本（`blender_pikmin_setup.py`）、APNG / GIF 打包腳本與 `.app` 打包腳本（`build_app.sh`）
