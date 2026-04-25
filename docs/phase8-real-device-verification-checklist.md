# Phase 8 — 真機驗證 Checklist

> 對應分支 HEAD `7ead8db`（Phase 1-8 完成、50 commits ahead of `ce4cadd`、395/0 tests）
> 在 paired iPhone 上跑（team JD337PDHDV 已是付費 Developer Program）
>
> **使用方式**：每項勾 `- [x]` 代表通過；不通過保留 `- [ ]` 並在下方 `> FAIL:` 行寫原因 + 重現步驟（最好附 screenshot / video 連結）

---

## ⚠️ Round 2 重點（Phase 8 期間 6 個新 commits — 看以下 5 個區域）

第一輪測試 (`60aebc5`) 後發現的問題已全部處理。重新測這幾項：

### Round 2 必測（Round 1 失敗或新加 surface）

1. **Camera capture（最大改動 — UIImagePickerController → AVCaptureSession 全重寫）**
   - 點 "Prove you're awake" → 應看到 **live camera preview** 全螢幕
   - 頂部置中：暖 charcoal 半透明小膠囊 "● Recording…"（coral 紅點 pulse 動畫）
   - 左上角：cream-50 半透明 X 按鈕（取消）
   - **2 秒後自動停止錄影**，自動切到 verifyingView（不需手動 tap stop）
   - 取消按鈕點下去 → 立即取消，回到 ringing
   - **錄影過程中鬧鐘聲應持續響**（這是 B2 修復重點 — 之前會被 picker 搶走）
   - 不應再看到 `Fig signalled err=-12710 / -17281` 或 `Result accumulator timeout` 錯誤
   - iPhone 17 Pro 的 BackTriple 應正常工作（原本 picker 不支援）

2. **Weekly insight 在 first-use 應隱藏**
   - 全清 app 重裝 → 首頁滑到底 → "WEEKLY INSIGHT" section 應顯示 "Your first insight will appear after a week of verified mornings."（不再是 14 天的假數據）
   - 完成至少一次 verified verify 後 → seed insight 才出現

3. **AlarmRingingView 時鐘**
   - "10:30 AM" 應在**單行**顯示（之前換行了，現在 minimumScaleFactor 自動縮）

4. **Home 滑動時 keyboard dismiss**
   - 在 commitment-note TextField 輸入 → 滑動 ScrollView → keyboard **應立即收起**（之前 .interactively 不收，現在 .immediately）

5. **Mic indicator 不應卡住**
   - 完成或取消 capture 後 → status bar 的橘色 mic 圓點應**立即消失**（之前 .playAndRecord 殘留）

### Round 1 已 PASS 的不需重測

Welcome flow / Permission primers / Baseline capture / Bedtime / Hero block / Streak nav cards / Sharing toggle / DEBUG section / DisableChallengeView 等 Round 1 標 [X] 的項目，除非 Round 2 commits 影響到（一般不會），不用重測。

---

---

## Metadata（測試前填）

- **測試日期**：2026年4月25日 10:15
- **測試者**：Vincent
- **設備型號**：iPhone 17 Pro
- **iOS 版本**：26.4.1
- **Build 來源**：Xcode Run 
- **HEAD SHA**：`60aebc51a2d2a6d45e43a95c7349e807db85c599`（測試時 `git rev-parse HEAD`）
- **API 預算狀態**：____________（前次 cumulative cost）

---

## 0. 設備準備

- [X] iPhone 連接、Xcode 識別、build target = WakeProof Debug
- [X] 確認 iOS 版本 ≥ 17.0
- [X] 從 Settings → General → iPhone Storage 完全 **delete WakeProof app**（清空 UserDefaults / SwiftData / 已授權 permissions）
- [X] Xcode Run（⌘R）安裝 fresh build
- [X] Console 開啟（⌘⇧Y）監看 log，整個 session 不應有 `error:` / `fault:` 級別

> FAIL notes：

---

## 1. Onboarding 全流程（Phase 5）

### 1.1 Welcome / Brand intro（Task 5.1）

- [X] 啟動後第一畫面：底色為 **warm charcoal**（不是純黑）
- [X] "WakeProof" wordmark 顯示為 **orange→coral 漸變**（不是純色）
- [X] Manifesto "An alarm your future self can't cheat." 用 SF Pro Rounded display 字（不是 Helvetica/Inter 感）
- [X] 主 CTA "Continue"（或既有 copy）為 cream pill button
- [X] 沒有 emoji，沒有 ! 標點

> FAIL notes：

### 1.2 Permission primers（Task 5.2 — 注意這裡是 grant rate 的關鍵）

- [X] 點 Begin → Notifications primer 出現
  - [X] Primer 文字：sentence case + em-dash 風格
  - [X] 點 primer 主按鈕 → **iOS 系統權限 alert 在 1 秒內彈出**（中間不該有 delay 或 black flash）
- [X] 同樣測 Camera primer：點主按鈕 → 系統 alert 應在 1 秒內彈
- [X] HealthKit primer（如有）：點主按鈕 → HealthKit sheet 立即彈
- [X] 拒絕任何一個 → 看到 **wpAttempted (#E07A2E 暖橘)** 警告 banner 而不是紅色

> FAIL notes：

### 1.3 Baseline 拍照（Task 5.3）

- [X] BaselinePhotoView 上方有 WPCard 包裹的 **location explainer copy**：「Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk. Capture it now in the lighting you'll see it in tomorrow morning.」
- [X] Title "Capture your baseline" 顯示
- [X] TextField "Label this spot" — **打字時文字為深 charcoal（不是純黑）**，背景 system roundedBorder
- [X] 拍照後 preview 圖最高 260pt、圓角 16pt
- [X] Location 未填時 Save button 為 **muted** 樣式（無 shadow，opacity 較低）
- [X] Location 填好 → Save button 變 **wpVerified 綠色**（primaryConfirm）
- [X] Save 後進入下一 step

> FAIL notes：

### 1.4 Bedtime + Contract-active confirmation（Task 5.4）

- [X] BedtimeStep "When do you sleep?" title 為 cream-50 + display 字
- [X] Toggle "Turn on overnight briefings" 可用，Tint 為 cream（不是 system blue）
- [X] DatePicker 文字 cream-50
- [X] 點 Save & continue **成功後**：
  - [X] 跳出 **WPCard 包裹的 confirmation card**：「Your contract is active — tomorrow at HH:MM, Claude will be waiting.」
  - [X] Card 下方有 **"Enter WakeProof" 按鈕**（不是 2 秒自動前進）
  - [X] 點按鈕才前進到首頁
- [ ] 點 Save 失敗（如關閉網路或破壞 UserDefaults）→ wpAttempted 暖橘警告，不會誤前進

> FAIL notes：

---

## 2. 首頁（AlarmSchedulerView — Phase 3）

### 2.1 Fresh install empty state（Task 3.5）

- [X] 第一次進入首頁、沒有 alarm 也沒有 attempt history → 看到 **"Your contract starts the night you set an alarm." 卡片 + "Set your first alarm" 按鈕**
- [X] 點按鈕 → ScrollView **自動滑到 "Wake window" section**（不是只跳一下，有 spring animation）

> FAIL notes：

### 2.2 Hero block（Task 3.1 + 3.2）

- [X] 大時鐘顯示**現在時間**（hh:mm），SF Pro Rounded 64pt
- [X] 時鐘**每秒 tick**（觀察分鐘變化時數字不抖動 — `monospacedDigit()` 生效）
- [X] 設定一個 alarm 後 → 時鐘下方出現 **"Next ring Mon Apr 26 06:30"** 灰色 footnote
- [X] 完成至少一次 verified verify → **WPStreakBadge** 在時鐘下方出現（wpVerified 綠膠囊 + "1 day"）
- [X] **點 Streak badge → 直接跳到 StreakCalendarView**（不是只是 visual feedback）

> FAIL notes：

### 2.3 First thing tomorrow card（Task 3.4）

- [X] WPSection title 為 **"FIRST THING TOMORROW"**（uppercase + tracking）
- [X] 下方 WPCard 內 TextField placeholder：「First thing tomorrow-you needs to do (optional)」
- [X] 打字 → 右下角 char counter 即時更新（"23/120" 之類）
- [X] 打到上限 → 自動 truncate（不能超過 120）
- [X] Keyboard return 鍵顯示 **"Done"**（不是 "return" 或 "go"）
- [FAIL] 滑動 ScrollView → keyboard 自動 dismiss（interactively）
- [X] 殺 app 重啟 → commitment note **保留**

> FAIL notes：

### 2.4 Wake window section

- [X] DatePicker "Start" 顯示時間
- [X] Toggle "Alarm enabled" — 開啟時保存生效
- [X] **Save & schedule** button 為 **wpVerified 綠色**（primaryConfirm）
- [ ] Save 失敗（模擬 UserDefaults 寫入失敗困難，跳過）→ 警告為 wpAttempted 暖橘色
- [X] 殺 app 重啟 → wake window 設定**保留**

> FAIL notes：

### 2.5 Your contract section（Task 3.3）

- [X] WPSection title "YOUR CONTRACT"
- [X] 下方有 **兩張並排的 WPCards**：
  - [X] 左卡：📕 (book.closed) coral icon + "Your commitment" + "Baseline age, mornings, insights"
  - [X] 右卡：📅 (calendar) verified-green icon + "Streak calendar" + "Every verified morning"
- [X] 點左卡 → 進入 InvestmentDashboardView
- [X] 點右卡 → 進入 StreakCalendarView
- [X] 兩張卡片**長按時有 visual feedback**（plain button style 但 SwiftUI 仍給 highlight）

> FAIL notes：

### 2.6 Sharing toggle（H5）

- [X] WPSection "SHARING" — Toggle "Allow sharing wake cards"
- [X] 預設 **OFF**（HOOK_S4_5）
- [X] 開啟 → 殺 app 重啟保留為 ON
- [X] 下方 footnote："Generate a minimalist image of your streak + Claude's observation to share manually. Nothing auto-posts."

> FAIL notes：

### 2.7 DEBUG section（#if DEBUG only — release build 應看不到）

- [X] WPSection "DEBUG" 出現
- [X] Toggle "Bypass disable challenge (DEV)" 可用
- [X] "Fire alarm now" 按鈕（紅色文字）
- [X] "Start overnight session now" 按鈕
- [X] "Finalize briefing now" 按鈕

> FAIL notes：

### 2.8 Weekly insight section（Task 6.7）

- [X] WPSection "WEEKLY INSIGHT" 出現
- [FAIL] 第一週尚無 insight 時 → empty state copy **"Your first insight will appear after a week of verified mornings."**（**不是** "run scripts/generate-weekly-insight.py"）
- [X] 有 insight 時：collapsed 顯示 2 行 subhead，點 chevron 展開全文 + "Generated X ago" footnote

> FAIL notes：

### 2.9 系統 banner 優先順序

依序模擬以下情境，確認 banner 顯示**正確、暖橘色（wpAttempted）**：

- [ ] 拒絕 Notifications → "Notifications are off — WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications."
- [ ] 飛行模式 + 過夜（讓 overnight 失敗）→ overnight 錯誤 banner
- [ ] HealthKit 拒絕 → HealthKit 不可用 banner

> FAIL notes：

---

## 3. 鬧鐘響 + 拍照驗證

### 3.1 設定 alarm + 等待（用 DEBUG "Fire alarm now" 加速）

- [X] DEBUG 區點 "Fire alarm now" → AlarmRingingView 全螢幕跳出

> FAIL notes：

### 3.2 AlarmRingingView（Task 6.1）

- [X] 底色 **wpChar900 暖 charcoal**（不是純黑 — 對比 iOS Settings 的純黑可看出 warmth）
- [X] 大時鐘 88pt rounded（用 WPHeroTimeDisplay）
- [X] 顯示 "Meet yourself at {location}." 或 fallback "Prove you're awake."
- [X] CTA "Prove you're awake" 為 **pill 形狀 + orange→coral 漸變 + coral glow shadow**
- [X] 沒有 dismiss 按鈕、沒有 X
- [X] 點 CTA → CameraCaptureView 全螢幕呈現（modal）

> FAIL notes：

### 3.3 CameraCaptureView（Task 6.8）

- [X] 真機：UIImagePickerController 相機 UI 立即出現
- [X] 在背景跳出來時、相機被取消時 → 看到 wpChar900 暖 charcoal background（**不是純黑 void**）
- [FAIL] 拍 2 秒影片 → 自動切回 verifyingView

> FAIL notes：

### 3.4 VerifyingView（Task 6.8）

- [X] 底色 wpChar900
- [X] sparkle.magnifyingglass icon **持續 pulse 動畫**（symbolEffect.pulse repeating）
- [X] "Verifying you're awake…" 文字 cream-50
- [ ] 重試時顯示 "Retry 1 of 1"
- [ ] Claude 回應錯誤時 → wpAttempted 暖橘錯誤訊息

> FAIL notes：

### 3.5 AntiSpoofActionPromptView（Task 6.6）— 若 Claude 要求 retry

- [ ] 底色 wpChar900
- [ ] "Now:" label cream-50 opacity 0.7
- [ ] Action verb（如 "Blink twice"）用 **wpCoral 強調**
- [ ] Subhead instructional 文字較淡

> FAIL notes：

---

## 4. Morning Briefing（Phase 4）

當 verify 成功（VERIFIED）→ MorningBriefingView 跳出。

### 4.1 Sunrise reveal animation（Task 4.1）

- [X] **底色不是純黑** — 是 sunrise 漸變從上(wpChar900) → rust → peach → cream100
- [X] 漸變**緩慢淡入**（1200ms easeOut，從黑到亮）
- [X] Status bar icons 在亮的部分仍**清晰可見**（dark color scheme forced，這是 Phase 7 的修正）

> FAIL notes：

### 4.2 內容順序與動畫（Task 4.2 + 4.3）

- [X] "Good morning" 顯示在頂部（display 42pt rounded, cream-50）
- [X] 今天日期顯示在 "Good morning" 下面（title3, cream-50 opacity 0.7）
- [X] 若 Onboarding 時有打 commitment note：
  - [X] Note 用 **大字（title2 28pt semibold）** 顯示，cream-50 opacity 0.95
  - [X] **Spring 動畫**從下方升起（offset 24→0、opacity 0→1，400ms 後啟動）
- [X] Briefing prose（Claude 寫的早晨文字）顯示
- [ ] 若 Claude 回了 observation（H1）：
  - [ ] 下方有 "Claude noticed" caption + observation italic
  - [ ] **Fade in 動畫**（900ms 後啟動，600ms easeOut）
  - [ ] CJK / 英文長 observation 不被截斷（lineLimit nil + fixedSize）

> FAIL notes：

### 4.3 CTA + share（Task 4.4）

- [X] **"Start your day"** primary white button 在底部
- [X] 點按鈕 **可感受到 success haptic**（短促兩下 — sensoryFeedback）
- [X] 點後 briefing dismiss
- [ ] **若**：沒開 sharing toggle / streak < 1 / 這次 verify 不是 success → **沒有 share 按鈕**
- [X] 開啟 sharing + streak ≥ 1 + verified → 看到 "Share streak" 之類 ShareLink 按鈕（cream-50 opacity 0.55 underline）
- [X] 點 ShareLink → 系統 share sheet 彈出
- [X] Share sheet 預覽圖 = ShareCardView（見 §6）

> FAIL notes：

### 4.4 BriefingResult 各案例

- [X] **No session**（沒設過 bedtime）→ 顯示 "No briefing this morning / Sleep well tonight — Claude will prepare one."
- [ ] **Failure**（network fail）→ 顯示 "Briefing unavailable / {error message}"
- [ ] **Nil**（防禦）→ defensive 顯示，不 crash

> FAIL notes：

---

## 5. Disable Challenge G1（Phase 6.2 + Wave 5 G1）

### 5.1 24h grace path（直接放行）

- [ ] 剛開啟 alarm（unverified streak 0）→ Toggle "Alarm enabled" OFF
- [ ] 預期 **Toggle 直接關**（24h 內 grace window 放行）
- [ ] Save & schedule 確認狀態為關

> FAIL notes：

### 5.2 24h 後 challenge required path

- [ ] Verify 過至少一次後等 24 小時 → Toggle OFF
- [ ] 預期 **Toggle 視覺保持 ON**（不會 visually flip）
- [ ] **DisableChallengeView 全螢幕跳出**

> FAIL notes：

### 5.3 DisableChallengeView 第一步：explainer（Task 6.2）

- [ ] 底色 wpChar900（暖 charcoal）
- [ ] **lock.shield SF Symbol** 64pt cream-50 opacity 0.9
- [ ] Title "Prove you're awake to disable." (title2)
- [ ] Body "Meet yourself at {location} first — same as a morning ring."
- [ ] **CTA 為 primaryAlarm**（pill + orange→coral 漸變 + coral glow，跟早上鬧鐘 CTA 一致）
- [ ] 取消按鈕：plain text，cream-50 opacity 0.6

> FAIL notes：

### 5.4 第二步：capture

- [ ] 點 challenge CTA → CameraCaptureView 全螢幕跳出（同早上 capture flow）
- [ ] 拍照 → verifyingView pulse → Claude 驗證
- [ ] **Verify 成功** → DisableChallengeView dismiss + Toggle visually flip 到 OFF（observer .onChange of scheduler.window.isEnabled）
- [ ] **Verify 失敗** → 留在 DisableChallengeView，Toggle 仍 ON

> FAIL notes：

### 5.5 DEBUG bypass

- [ ] DEBUG 區開啟 "Bypass disable challenge (DEV)" → Toggle OFF 直接生效，不會跳 challenge
- [ ] 關掉 bypass → 回到 challenge required path

> FAIL notes：

---

## 6. Streak Calendar 與 Investment Dashboard

### 6.1 StreakCalendarView（Task 6.3）

- [ ] 底色 **cream-100**（光面）
- [ ] 月份 header (title3, wpChar900)
- [ ] Weekday header（caption + tracking 1.5）
- [ ] **Verified 日**：wpVerified 綠色填滿 + cream-50 checkmark
- [ ] **Attempted but not verified**：wpAttempted 暖橘色 stroke / fill
- [ ] **缺席日**：wpChar300 stroke 圓圈
- [ ] 圖例（legend）使用相同 token
- [ ] 滑動月份切換正常

> FAIL notes：

### 6.2 InvestmentDashboardView（Task 6.4）

- [ ] 底色 cream-100
- [ ] **三張 WPMetricCard**：
  - [ ] Baseline age（baseline 拍了幾天）
  - [ ] **Verified mornings**（accent: true → 數字用 orange→coral 漸變）
  - [ ] Insights collected
- [ ] 框架文案 "Apple Clock doesn't know you. WakeProof has N of your mornings."（title3 + wpChar900）
- [ ] **VoiceOver 測試**：focus 一張 metric card → 應**單一聲明** "12. Verified mornings."（不是 "12" pause "Verified mornings"）

> FAIL notes：

---

## 7. Share Card（Wave 5 H5 + Task 6.7 + Phase 7 contrast fix）

### 7.1 觸發 share

- [ ] 開啟 sharing toggle、verify 成功、streak ≥ 1 → MorningBriefing share button 出現
- [ ] 點 share → ShareLink 系統 share sheet 預覽圖出現

> FAIL notes：

### 7.2 ShareCard 視覺

- [ ] 1080×1920 portrait
- [ ] 底色 **orange→coral 135° 漸變**（不是純黑、不是純色）
- [ ] **大數字（streak）300pt bold cream-50** monospacedDigit
- [ ] "day streak" 字幕 (title1 34pt) cream-50 opacity 0.85
- [ ] **若有 observation：22pt italic cream-50 opacity 0.85**（這是 Phase 7 contrast 修正 — 16pt 之前 fail WCAG）
  - [ ] 在實機看 ShareCard → observation 字**清晰可讀**（不會被漸變蓋掉）
- [ ] 右下角 "WAKEPROOF" 浮水印 caption + tracking(2) + uppercase + opacity 0.7
- [ ] 圖片可分享到 Photos / Messages / IG Story 等

> FAIL notes：

---

## 8. 跨頁面設計一致性

### 8.1 顏色

- [ ] 任何深色 hero（AlarmRing / DisableChallenge / Verifying / MorningBriefing / Onboarding）→ **沒有純黑**（看起來是暖 charcoal）
- [ ] 任何淺色 surface（Home / Dashboard / Calendar / WeeklyInsight）→ **沒有純白**（看起來是 cream）
- [ ] 警告色一致用 wpAttempted（暖橘 #E07A2E），不是紅色或黃色
- [ ] 成功色一致用 wpVerified（leafy green #4E8F47），不是 system blue/green

> FAIL notes：

### 8.2 字型

- [ ] 大時鐘 / streak 數字 / "Good morning" → SF Pro Rounded（warm + rounded letterforms）
- [ ] Body / button 文字 → SF Pro 系統預設
- [ ] 沒有 Helvetica / Inter / Roboto 出現

> FAIL notes：

### 8.3 間距 / 圓角 / shadow

- [ ] WPCard：20pt 圓角 + 暖 shadow（淺色），dark mode 時 wpChar800 + 1px hairline 而非 shadow
- [ ] PrimaryButton：14pt 圓角（standard）/ pill（alarm）
- [ ] Section 之間留 24pt 縱向間距（screen padding 32pt）

> FAIL notes：

### 8.4 文案 voice

- [ ] 全部 sentence case（"Wake window" 而不是 "Wake Window"）
- [ ] em-dash（—）作為強調連字（"Streak reset — tomorrow's a fresh start."）
- [ ] **沒有 emoji**
- [ ] 沒有「achievement / unlock / level / score / points」這類 gamification 詞彙
- [ ] 第二人稱（"you"）一致

> FAIL notes：

---

## 9. 邊界與配件

### 9.1 系統 Light vs Dark mode

打開 iOS Settings → Display → Light / Dark 切換：

- [ ] **Light 模式**：Home / Calendar / Dashboard / WeeklyInsight 為 cream surface
- [ ] **Dark 模式**：Home / Calendar / Dashboard / WeeklyInsight 為 wpChar800 surface + 1px hairline
- [ ] **Hero views 永遠暗色**（AlarmRing / DisableChallenge / Verifying / MorningBriefing / Onboarding 在 Light 系統下也維持 wpChar900 + dark color scheme — `.preferredColorScheme(.dark)` 強制）
- [ ] **MorningBriefing 在 Light 系統下**：status bar 文字 / icon **仍清晰可讀**（這是 Phase 7 修的 bug）

> FAIL notes：

### 9.2 iPhone SE / 小螢幕

如有 iPhone SE 或 iPhone mini：

- [ ] AlarmSchedulerView 滾動正常，commitment-note TextField **獲得焦點時不被 keyboard 遮住**（這是 Phase 3.1 fix 的關鍵）
- [ ] MorningBriefing 的 commitment note 不會被截斷
- [ ] Observation block CJK / EN 都不會 overflow（48pt horizontal padding 留 ~279pt 寬度）

> FAIL notes：

### 9.3 Dynamic Type

iOS Settings → Accessibility → Display & Text Size → Larger Text → 拉到最大：

- [ ] **Note**: WPFont 目前是 fixed-size（不 scale Dynamic Type — Phase 7 UAT 標為已知 trade-off，App Store proper review 前需 audit）。實測時記下哪些 surface 在 large text 下視覺**最緊張**（用於後續 backlog）

> FAIL notes / 觀察：

### 9.4 VoiceOver

iOS Settings → Accessibility → VoiceOver → ON：

- [ ] Home 頁面：focus WPMetricCard / WPStreakBadge → **單一聲明**（不是 value + label 兩段）
- [ ] AlarmRingingView：時鐘 + "Meet yourself at..." 都可 focus，CTA 可 activate
- [ ] DisableChallengeView：lock.shield 不被 focus（純裝飾）, title + body + CTA 三個 focus stops
- [ ] WeeklyInsightView：collapsed 時 chevron 有 "Expand insight" / "Collapse insight" label

> FAIL notes：

### 9.5 Background / 過夜真實 alarm（**這是真機驗證的核心**）

- [ ] 設一個 5 分鐘後的 alarm + 寫 commitment note
- [ ] 鎖屏、靜音模式
- [ ] 等鬧鐘響：
  - [ ] **音量正常響起**（audio session keepalive 生效）
  - [ ] AlarmRingingView 全螢幕 take over lock screen
  - [ ] 拍照 → Claude 驗證
  - [ ] Morning Briefing **看到 commitment note** 從黑色畫面 spring 入
  - [ ] Sunrise gradient 緩慢淡入 1.2 秒
  - [ ] 點 "Start your day" 感受 haptic
- [ ] 隔天早上設 8AM 真實 alarm，**睡覺**，第二天測整個 wake-up flow（demo 必跑路徑）

> FAIL notes：

### 9.6 Streak 進度

- [ ] 連續 verify 兩天 → home WPStreakBadge 應顯示 "2 days"
- [ ] StreakCalendarView 應有兩個 wpVerified 綠色 cell
- [ ] InvestmentDashboard "Verified mornings" 應為 2

> FAIL notes：

### 9.7 Long-running edge case

- [ ] 開飛航模式 → fire alarm → verify → 看到 wpAttempted error banner（Claude API unreachable），但 alarm 仍可 dismiss（fallback 路徑）

> FAIL notes：

---

## 10. Demo recording 模擬

實際錄一段 ~2-3 分鐘 demo（為 hackathon submission）：

- [ ] Cold start → onboarding 完整跑完
- [ ] Set alarm 30 秒後 → 鎖屏 → 響鈴 → 拍照 → verify → MorningBriefing 完整看完
- [ ] Streak badge 點開 calendar
- [ ] Your commitment 點開 dashboard
- [ ] 開啟 sharing → 隔天再 verify 一次 → share card 出現
- [ ] DEBUG bypass 開啟 → 直接關鬧鐘
- [ ] DEBUG bypass 關閉 → 嘗試關鬧鐘 → DisableChallengeView 跳出 → 完整跑完 challenge
- [ ] Recording 檔案備份到（路徑 / 雲端）：____________

> FAIL notes：

---

## 結果總結（測試後填）

- **總計**：____ 通過 / ____ 失敗 / ____ 觀察項
- **API 累計花費**：$____________
- **總測試時長**：____________
- **Demo recording 是否就緒**：[ ] Yes / [ ] No
- **是否 ready 進 Phase 9 push**：[ ] Yes / [ ] No / [ ] 需先修 Failures

### 失敗項摘要（complete the rows）

| Section | 項目 | 失敗原因 | Screenshot/Video | 嚴重度 |
|---|---|---|---|---|
| | | | | |
| | | | | |

### Known trade-offs / 已知妥協（不算失敗）

-
-

### 後續 backlog（不影響本次驗收，但需追蹤）

-
-

---

## 回報給 Claude 的範本

複製貼上：

```
真機驗證結果（HEAD 60aebc5）：
- 設備：iPhone XX（iOS XX.X）
- 通過：X/X 項
- 失敗：X 項
  1. [Section] 項目 — 原因 — 重現步驟
  2. ...
- API 累計：$X.XX
- Demo recording：✓ / ✗（連結：）
- 結論：APPROVE Phase 9 push / 需先修 X 項 / BLOCK
```
