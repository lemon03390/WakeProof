# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Primary Reference

- **`AGENTS.md`** — 專案結構、指令、開發指引、文檔資源
- **本文件** — 核心開發規則（永遠生效）
- **`~/.claude/projects/.../memory/`** — Skills 索引與跨對話記憶

---

## 核心開發準則

### 開發哲學

- **小步前進** — 每次改動都能編譯、通過測試，避免大爆炸式修改
- **先理解再動手** — 找到 3 個類似的現有實作，學習其模式後才開始寫
- **務實不教條** — 依專案實際情況調整，不為追求理論完美而過度設計
- **意圖清晰** — 選擇直白的寫法，如果需要解釋，說明它太複雜了
- **單一職責** — 每個函數/組件只做一件事
- **避免過早抽象** — 等到第三次重複時才考慮抽取

### 工作流程

#### 複雜任務分階段

超過 3 步的任務，使用 TodoWrite 工具拆分為 3-5 個階段：

- 每階段有明確的交付物和驗收標準
- 逐階段完成，每階段確保編譯通過
- 完成一個階段才進入下一個

#### 實作順序

1. **理解** — 閱讀現有程式碼，找到相似功能的實作模式
2. **測試** — 核心業務邏輯先寫測試（參照測試編寫規範）
3. **實作** — 寫最少的程式碼讓測試通過
4. **清理** — 在測試通過的前提下重構
5. **提交** — commit message 說明「為什麼」而非「做了什麼」

#### 卡關協議（CRITICAL）

**同一問題最多嘗試 3 次，然後必須停下來。**

停下後：

1. 記錄嘗試過的方法和具體錯誤訊息
2. 質疑基本假設 — 抽象層級對嗎？能拆成更小的問題嗎？有更簡單的方式嗎？
3. 尋找替代方案 — 不同的函式庫功能？不同的架構模式？減少抽象而非增加？
4. 向用戶報告情況，提出 2-3 個替代方向供選擇

### 決策框架

當存在多個可行方案時，依此優先順序選擇：

1. **可測試性** — 能輕鬆測試嗎？
2. **可讀性** — 六個月後還能看懂嗎？
3. **一致性** — 符合專案現有模式嗎？
4. **簡潔性** — 這是最簡單的可行方案嗎？
5. **可逆性** — 之後要改有多難？

### 品質關卡

#### 多 Wave 修復計劃的驗收流程（MANDATORY — 不可跳步）

當執行分 Wave 的修復計劃（如 adversarial review remediation）時，每完成一個 Wave 必須依序走完：

1. **完成 Wave** — 所有 tasks 實作完畢
2. **Adversarial Review** — 對本 Wave 修改進行對抗性審查
3. **修復** — 修復審查發現的問題
4. **整合審查** — 跨修復一致性驗證（SQL + EF + Frontend）
5. **`/simplify`** — 代碼簡化
6. **PR Review** (`/pr-review-toolkit:review-pr`) — 正式 PR 審查
7. **修復** — 修復 PR review 發現的問題
8. **`/simplify`** — 再次簡化
9. **PR Review 確認零 issue** — 若仍有 issue，重複步驟 7-9
10. **進入下一個 Wave**

需要人手參與的任務（如需業主決策）自行押後，不阻塞流程。

#### Adversarial Review / PR Review 的 Issue 處理標準（MANDATORY）

Adversarial review 或 `/pr-review-toolkit:review-pr` 產出的**所有** issue — 不論嚴重度（Critical、Important、Medium、Low）— **都必須處理**。唯一例外是經判斷「不修也可」的 issue，此時必須附帶理由說明為何不修。

「處理」的定義：

- **修復** — 直接修改代碼解決問題
- **明確標記不修** — 附帶技術理由（如「已由 server-side RPC 保護」「屬產品設計決策」）

禁止：

- 只處理 Critical/High 而忽略 Medium/Low
- 以「低風險」為由跳過不處理而不附理由
- 在 PR review 仍有未處理 issue 的情況下進入下一個 Wave

#### 每次提交前

- [ ] 編譯成功，無 linter 警告
- [ ] 相關測試通過（詳見測試編寫規範）
- [ ] 錯誤處理遵循統一模式（詳見統一錯誤處理規範）
- [ ] 遵循專案現有程式碼風格
- [ ] commit message 清楚說明變更原因

### 禁止事項

- 禁止用 `--no-verify` 跳過 commit hooks
- 禁止 disable 測試而非修復測試
- 禁止提交無法編譯的程式碼
- 禁止假設 — 先查看現有程式碼驗證
- 避免留下無說明的 TODO，每個 TODO 附帶原因
- 費用相關與不可逆操作的限制，詳見下方費用安全規範

---

## 費用安全與不可逆操作保護

**所有可能產生費用或不可逆的操作，必須經用戶明確指示後才能執行。**

### 禁止自動執行的操作

- `eas build` / `build_submit` — 觸發 build 或提交到 App Store
- `eas update` — 發佈 OTA 更新到生產環境
- `workflow_run` — 觸發 EAS Workflow
- `git push` / `git push --force` / `git rebase` / `git reset --hard`
- 自動生成 `.md` 文件（除非用戶要求）

### 執行前必要步驟

1. 確認操作內容
2. 說明影響範圍與費用估算
3. 等待用戶明確確認

### 允許自動執行的安全操作

- `build_list` / `build_info` / `build_logs` — 查看狀態（唯讀）
- `workflow_list` / `workflow_validate` — 查看/驗證（唯讀）
- `learn` / `search_documentation` — 查閱文檔
- `automation_take_screenshot` / `automation_tap_by_testid` — 本地自動化
- `git add` / `git commit` — 本地操作（僅在用戶要求時）

---

## 統一錯誤處理規範

適用範圍：`app/**/*.tsx`, `components/**/*.tsx`, `hooks/**/*.ts`, `lib/**/*.ts`

### 核心原則

1. **唯一入口**：所有錯誤通過 `lib/error-handler.ts` 的 `showError()` 或 `handleError()` 處理
2. **禁止直接 Alert**：禁止 `Alert.alert('錯誤', ...)` 硬編碼錯誤訊息
3. **類型安全**：`catch` 區塊使用 `unknown` 而非 `any`

### 標準錯誤處理模式

#### Supabase 查詢錯誤

```typescript
import { showError } from '@/lib/error-handler'

async function fetchPatients() {
  try {
    const { data, error } = await supabase.from('patients').select('*')
    if (error) {
      showError(error, '載入患者列表')
      return
    }
    // 使用 data
  } catch (error: unknown) {
    showError(error, '載入患者列表')
  }
}
```

#### 操作型錯誤（新增/修改/刪除）

```typescript
import { showError, showSuccess } from '@/lib/error-handler'

async function handleSave() {
  try {
    const { error } = await supabase.from('records').insert(newRecord)
    if (error) {
      showError(error, '儲存記錄')
      return
    }
    showSuccess('記錄已儲存')
  } catch (error: unknown) {
    showError(error, '儲存記錄')
  }
}
```

#### 確認型操作（刪除/危險操作）

```typescript
import { showDestructiveConfirm } from '@/utils/alert'
import { showError, showSuccess } from '@/lib/error-handler'

function handleDelete(id: string) {
  showDestructiveConfirm('確認刪除', '刪除後無法恢復，確定要刪除嗎？', async () => {
    try {
      const { error } = await supabase.from('records').delete().eq('id', id)
      if (error) {
        showError(error, '刪除記錄')
        return
      }
      showSuccess('記錄已刪除')
    } catch (error: unknown) {
      showError(error, '刪除記錄')
    }
  })
}
```

### 禁止的模式

```typescript
// BAD: 直接 Alert.alert
Alert.alert('錯誤', '操作失敗');
Alert.alert('錯誤', error.message);

// BAD: catch (error: any)
catch (error: any) { ... }

// BAD: 僅 console.log 不通知用戶
catch (error) {
  console.log('Error:', error);
}

// BAD: 忽略 Supabase error
const { data, error } = await supabase.from('x').select('*');
// 直接使用 data 不檢查 error
```

### 允許的模式

```typescript
// GOOD: 使用 showError
showError(error, '載入資料');

// GOOD: catch unknown + showError
catch (error: unknown) {
  showError(error, '操作名稱');
}

// GOOD: 檢查 Supabase error
const { data, error } = await supabase.from('x').select('*');
if (error) {
  showError(error, '查詢');
  return;
}

// GOOD: 非關鍵失敗可以僅記錄（如庫存扣減失敗不阻斷診症）
// 注意：生產環境使用 logWarn 而非 console.warn — console.* 在正式環境對用戶不可見
// 且不進入 application_error_log sink，等同靜默失敗。
import { logWarn } from '@/lib/logger'
if (stockError) {
  logWarn('consultationSubmit.deductStock', '庫存扣減失敗（非阻斷）', stockError)
}
```

### 結構化日誌（logger）— 非 UI 錯誤觀測

適用於：不需中斷用戶流程、但需在生產環境可被觀測的警告/錯誤（背景 refresh 失敗、非關鍵 RPC 降級、audit trail 寫入失敗等）。

```typescript
import { logError, logWarn } from '@/lib/logger'

// 錯誤（會寫入 application_error_log sink）
try {
  // ...
} catch (error: unknown) {
  logError('moduleOrFile.functionName', '描述性訊息', error, { id, context })
}

// 警告（同樣會寫入 sink）
logWarn('moduleOrFile.functionName', '描述性訊息', error, { id, context })
```

**簽名**：`logError(fn, message, error, extra?)` / `logWarn(fn, message, detail?, extra?)`

**傳遞原則**：

- `fn`: 用 `file.function` 或 `module.operation` 格式，方便 dashboard 搜尋
- `message`: 人類可讀、保留描述性文字
- `detail`: 原始 error 物件（PostgrestError、Error、或 unknown）。**不要**手動抽取 `.message` — `extractError` 會自動抽取 `code`/`hint`/`details`/`stack` 等結構化欄位
- `extra`: 需要額外觀測的 ID、計數、狀態等

**showError vs logError/logWarn 的差別**：
| 情境 | 使用 |
|---|---|
| 用戶需看到錯誤對話框 | `showError(error, '操作名稱')` |
| 用戶需看到成功提示 | `showSuccess('訊息')` |
| 非關鍵背景失敗（不顯示對話框，但需可觀測） | `logWarn(fn, msg, error)` |
| 關鍵內部錯誤（catch 到後繼續流程但需警報） | `logError(fn, msg, error)` |
| 用戶操作失敗 | 先 `logError` 記錄 + `showError` 顯示 |

禁用 `console.warn` / `console.error` 於業務邏輯路徑（`if (__DEV__) console.log(...)` 的開發輸出例外）。

### 成功提示

```typescript
import { showSuccess } from '@/lib/error-handler'

// 使用統一的 showSuccess
showSuccess('患者資料已更新')
```

### 確認對話框

```typescript
import { showConfirm, showDestructiveConfirm } from '@/utils/alert'

// 普通確認
showConfirm('確認', '確定要提交嗎？', onConfirm)

// 破壞性確認（刪除等）
showDestructiveConfirm('確認刪除', '此操作無法撤銷', onConfirm, '刪除')
```

### error-handler.ts 中 handleError 的職責

1. 將 Supabase 錯誤碼（23505、23503、42501 等）映射為用戶友好訊息
2. 在 `__DEV__` 模式下輸出詳細錯誤日誌
3. 返回用戶友好的錯誤訊息字串
4. `showError()` = `handleError()` + `Alert.alert()`

---

## 測試編寫規範

適用範圍：`**/__tests__/**`, `**/*.test.ts`, `**/*.test.tsx`

### 核心原則

1. **行為驅動**：測試業務規則和操作順序，不測試實作細節
2. **模擬業務流程**：用 `simulateXxx()` 函數模擬畫面中的核心流程
3. **全面覆蓋**：每個巨型檔案拆分前必須有完整測試護欄

### 檔案位置與命名

```
lib/__tests__/
  consultation-save-logic.test.ts     # 業務邏輯測試（模擬畫面流程）
  payment-flow-logic.test.ts
  discount-calculator.test.ts         # 純函數單元測試

components/__tests__/
  Auth.behavior.test.ts               # 組件行為測試

app/__tests__/
  consultation.integration.test.tsx   # 畫面整合測試（較少使用）
```

#### 命名規則

- 業務流程測試：`{feature}-{flow}-logic.test.ts`
- 純函數測試：`{module-name}.test.ts`
- 組件行為測試：`{Component}.behavior.test.ts`
- 整合測試：`{feature}.integration.test.ts`

### Supabase Mock 策略

#### 全局 Mock（jest.setup.ts 已配置）

`jest.setup.ts` 已 mock 以下模組，所有測試自動繼承：

- `lib/supabase` — Supabase 客戶端
- `lib/connection-manager` — 連線管理器
- `lib/organization-context` — 組織上下文

#### 測試內自訂 Mock

使用 `jest.requireMock` 取得 mock 實例進行自訂：

```typescript
const mockSupabaseModule = jest.requireMock('../supabase') as {
  supabase: { from: jest.Mock; rpc: jest.Mock }
}
```

#### 多次鏈式呼叫 Mock（標準模式）

```typescript
function buildMultiCallMock(responses: Array<{ data: any; error: any }>) {
  let idx = 0
  mockSupabaseModule.supabase.from = jest.fn(() => {
    const chain: any = {}
    const methods = [
      'select',
      'insert',
      'update',
      'delete',
      'eq',
      'in',
      'single',
      'order',
      'limit',
      'range',
      'maybeSingle',
    ]
    methods.forEach((m) => {
      chain[m] = jest.fn().mockReturnValue(chain)
    })
    chain.then = (resolve: any) => {
      const resp = responses[idx] ?? { data: null, error: null }
      idx++
      return Promise.resolve(resp).then(resolve)
    }
    return chain
  })
}
```

#### 可重用 Mock 工廠（test/utils/mockSupabase.ts）

```typescript
import { createMockSupabase, createChainableMock } from '@/test/utils/mockSupabase';

const { supabase, mockFrom, mockRpc } = createMockSupabase({
  fromResult: { data: [...], error: null },
});
```

### 業務流程測試模式

#### simulate 函數模式（核心模式）

為每個畫面的關鍵流程建立 `simulateXxx()` 函數，模擬畫面中的操作步驟：

```typescript
async function simulateConsultationSave(
  params: {
    waitingId: string
    patientId: string
    hasPrescriptions: boolean
    medicines?: Array<{ medicine_id: string; deduct_quantity: number }>
  },
  supabase = mockSupabaseModule.supabase
): Promise<{
  success: boolean
  operationOrder: string[] // 記錄操作順序
  error?: string
}> {
  const operationOrder: string[] = []

  try {
    operationOrder.push('insert_consultation_records')
    // ... 模擬業務步驟 ...
    return { success: true, operationOrder }
  } catch (error: unknown) {
    return { success: false, operationOrder, error: String(error) }
  }
}
```

### 必測項目

每個業務流程測試必須覆蓋：

1. **操作順序**（CRITICAL）：驗證資料庫操作的先後順序
2. **失敗韌性**：非關鍵操作失敗不應阻斷主流程
3. **狀態轉換**：驗證 waiting_list 等狀態欄位的正確值
4. **早期失敗**：主操作失敗時後續操作不應執行
5. **資料正確性**：驗證傳給 RPC/insert 的參數

### 測試結構模板

```typescript
/**
 * Behavioral Tests — {Feature} Flow
 *
 * Tests the BUSINESS RULES of {file}.tsx:
 *   1. {Rule 1}
 *   2. {Rule 2}
 */

const mockSupabaseModule = jest.requireMock('../supabase') as { ... };

// Simulate function
async function simulate{Feature}(params: {...}): Promise<{...}> { ... }

// Mock helpers
function buildMultiCallMock(responses: any[]) { ... }

const baseParams = { ... };

beforeEach(() => { jest.clearAllMocks(); });

// A. Operation Order (CRITICAL)
describe('{Feature}: Operation Order', () => { ... });

// B. Failure Resilience
describe('{Feature}: Failure Resilience', () => { ... });

// C. Status/State Logic
describe('{Feature}: Status Logic', () => { ... });

// D. Early Failure Handling
describe('{Feature}: Early Failure', () => { ... });

// E. Data Correctness
describe('{Feature}: Data Correctness', () => { ... });
```

### 純函數單元測試

對於 `lib/` 中的計算函數，直接 import 測試：

```typescript
import { DiscountCalculator } from '../discount-calculator'

describe('DiscountCalculator', () => {
  test('fixed amount discount', () => {
    const result = DiscountCalculator.calculate(1000, [
      { discount_id: 'd1', discount_name: '折扣', discount_type: 'fixed_amount', discount_value: 100 },
    ])
    expect(result).toBe(100)
  })
})
```

### beforeEach 規範

每個測試檔案必須在 `beforeEach` 中清理 mock：

```typescript
beforeEach(() => {
  jest.clearAllMocks()
})
```

### 覆蓋要求

#### P0 巨型檔案（拆分前必備）

- 每個 simulate 函數覆蓋所有主要分支
- 操作順序測試 ≥ 3 個
- 失敗韌性測試 ≥ 2 個
- 狀態轉換測試 ≥ 2 個
- 預計每檔 20-50 個測試案例

#### P1 核心業務流程

- 覆蓋診症、付款、庫存、薪資、預約五大流程
- 每個流程 ≥ 15 個測試案例

### 執行測試

```bash
# 執行全部測試
npm test

# 執行單一測試檔案
npx jest lib/__tests__/consultation-save-logic.test.ts

# 執行匹配模式的測試
npx jest --testPathPattern="consultation"

# 查看覆蓋率
npx jest --coverage
```

---

## 測試紀律

測試失敗時的處理順序：

1. 先理解測試在驗證什麼業務規則
2. 檢查生產代碼是否有 bug
3. 如果是生產代碼的 bug → 修生產代碼
4. 如果是測試本身過時（例如 API 簽名改了）→ 更新測試
5. 永遠不要僅僅為了讓測試通過而修改 expect 的值

### 禁止行為

- 不准把 `expect(result).toBe(350)` 改成 `expect(result).toBe(349.99)`
- 不准把 `expect(fn).toThrow()` 改成 `expect(fn).not.toThrow()`
- 不准在測試裡加 try-catch 吞掉錯誤
- 不准把失敗的測試標記為 `.skip`

---

## 檔案拆分與重構規範

適用於超過 500 行的畫面檔案。

### 核心原則

1. **先測試再拆分**：目標檔案必須有完整測試通過後才能開始拆分
2. **小步前進**：每次只提取一個 hook 或一個子組件，立即跑測試
3. **行為不變**：拆分是純粹的結構重構，不改變任何業務邏輯

### 目錄結構

拆分後的畫面檔案應遵循以下結構：

```
app/
  consultation.tsx              # 主畫面（組合層，< 300 行）
components/
  consultation/                 # 子組件目錄（以功能命名）
    ConsultationForm.tsx         # 表單區子組件
    ConsultationList.tsx         # 列表區子組件
    ConsultationModal.tsx        # 彈窗子組件
    index.ts                     # barrel export
hooks/
  consultation/                 # 業務邏輯 hooks
    useConsultationData.ts       # 資料查詢與狀態
    useConsultationActions.ts    # 操作與提交邏輯
    index.ts                     # barrel export
```

### Hook 提取規則

#### 命名規範

- 資料查詢：`use{Feature}Data` — 負責 Supabase 查詢、資料載入、分頁
- 操作邏輯：`use{Feature}Actions` — 負責新增、修改、刪除、提交
- 表單狀態：`use{Feature}Form` — 負責表單 state、驗證、重置
- 篩選邏輯：`use{Feature}Filters` — 負責搜尋、排序、過濾條件

#### Hook 結構模板

```typescript
export function useConsultationData(orgId: string, branchId: string) {
  const [data, setData] = useState<ConsultationType[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    // ... Supabase query
  }, [orgId, branchId])

  useEffect(() => {
    fetchData()
    return () => {
      /* cleanup */
    }
  }, [fetchData])

  return { data, loading, error, refresh: fetchData }
}
```

#### 提取判斷標準

- 超過 20 行的 `useState` + `useEffect` 組合 → 提取為 hook
- 超過 15 行的事件處理函數 → 提取到 `useActions` hook
- 多個 state 共同支撐一個功能區 → 合併為一個 hook

### 子組件拆分規則

#### 命名規範

- 統一使用 **PascalCase** 檔名和組件名
- 統一使用 **named export**（`export function ComponentName`）
- 禁止使用 `export default`

#### Props 傳遞模式

- 定義明確的 Props interface，放在組件檔案頂部
- 避免超過 8 個 props，過多時考慮合併為 config 物件
- callback props 命名為 `on{Action}`（如 `onSubmit`, `onDelete`）

```typescript
interface ConsultationFormProps {
  patientId: string
  initialData?: ConsultationFormData
  onSubmit: (data: ConsultationFormData) => Promise<void>
  onCancel: () => void
}

export function ConsultationForm({ patientId, initialData, onSubmit, onCancel }: ConsultationFormProps) {
  // ...
}
```

#### 拆分判斷標準

- JSX 中 > 50 行的區塊 → 拆為子組件
- 帶有獨立 state 的 UI 區塊 → 拆為子組件
- 被 `{condition && (...)}` 包裹的大段 JSX → 拆為子組件
- Modal/Dialog 內容 → 一律拆為獨立組件

### StyleSheet 處理

- 畫面主檔案的 StyleSheet 保留在主檔案底部
- 子組件的 StyleSheet 放在各自檔案內
- 共用樣式提取到 `constants/shared-styles.ts`
- 禁止 inline style（動態樣式除外，如 `style={{ opacity: disabled ? 0.5 : 1 }}`）

### 主畫面組合層模板

拆分後的主畫面應該只負責組合，不包含業務邏輯：

```typescript
export default function ConsultationScreen() {
  const { orgId, branchId } = useOrgBranchIds();
  const { data, loading, refresh } = useConsultationData(orgId, branchId);
  const { handleSubmit, handleDelete } = useConsultationActions(orgId);

  if (loading) return <LoadingScreen />;

  return (
    <WebPageLayout title="診症記錄">
      <ConsultationForm onSubmit={handleSubmit} />
      <ConsultationList data={data} onDelete={handleDelete} />
    </WebPageLayout>
  );
}
```

### 重構檢查清單

每次拆分完成後確認：

- [ ] 所有 P0 測試通過
- [ ] 主畫面 < 300 行
- [ ] 每個子組件 < 300 行
- [ ] 每個 hook < 200 行
- [ ] 無 circular import
- [ ] 所有 props 有 TypeScript 類型定義
- [ ] useEffect 有清理函數
