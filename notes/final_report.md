# 基於 Btrfs CoW 機制之 Rust 編譯環境快速部署與儲存最佳化研究

## (一) 摘要

隨著 Rust 語言在系統程式設計領域的普及，其嚴格的編譯檢查與靜態分析雖然保證了記憶體安全，但也帶來了顯著的編譯時間成本與磁碟空間消耗。特別是在多分支開發（Multi-branch Development）場景下，開發者往往面臨「切換分支需重新編譯」或「維護多個工作目錄導致磁碟耗盡」的兩難局面。

本研究提出一套名為「Cargo-CoW」的實驗性架構，利用 Btrfs 檔案系統的寫入時複製（Copy-on-Write, CoW）與 Reflink（Reference link）機制，結合 Git Worktree，實現建置環境的秒級複製與還原。實驗結果顯示，在磁碟空間效率方面，本架構結合 Zstd 透明壓縮可節省高達 **77%** 的物理儲存空間。在建置效能方面，對於無複雜外部依賴的中小型專案（如 `ripgrep`），冷啟動建置速度提升了 **1.46 倍**。

然而，研究亦發現此技術存在兩大限制：(1) 檔案系統操作存在約 2.5 秒的固定開銷，使其不適合微量修改的增量編譯場景；(2) Rust 建置系統（Cargo）對「絕對路徑」的高度敏感性，導致在依賴複雜的大型專案（如 `Zed Editor`）中，跨目錄還原的快取會因指紋（Fingerprint）不匹配而失效。本研究總結認為，單純的檔案系統層級最佳化不足以完全解決 Rust 的快取重用問題，未來需結合容器化技術（Namespace Isolation）以固定路徑來規避 Cargo 的雜湊檢查。

## (二) 研究動機與研究問題

### 2.1 研究動機
Rust 的編譯單元（Crate）模型與單態化（Monomorphization）特性，使得其編譯產物（`target/` 目錄）體積龐大。在現代 CI/CD 流程或多人協作開發中，頻繁的分支切換（Context Switch）是常態。目前開發者主要採取兩種策略：
1.  **單一工作目錄**：切換 Git 分支時，Cargo 檢測到原始碼變更，往往觸發大規模重新編譯，浪費時間。
2.  **多個工作目錄 (Git Worktree)**：為每個分支建立獨立目錄，雖然避免了重編，但每個目錄都需獨立的 `target/`，導致磁碟空間呈倍數增長（數十 GB 至數百 GB）。

### 2.2 研究問題
本研究試圖回答以下核心問題：
1.  能否利用現代檔案系統（Btrfs/XFS）的 Reflink 技術，在不佔用額外實體空間的前提下，實現 `target/` 目錄的瞬間複製？
2.  透過 Reflink 複製的建置快取（Build Cache），能否被 Cargo 有效識別並重用，從而加速新分支的冷啟動（Cold Start）？
3.  此機制在不同規模（純 Rust vs. 混合 C++）的專案中，其效能表現與適用邊界為何？

## (三) 文獻回顧與探討

### 3.1 Rust 編譯快取機制
Cargo 的快取機制採用了**雙層新鮮度模型 (Double-Layer Freshness Model)**：
1.  **檔案系統時間戳記 (Mtime Check)**：Cargo 首先檢查原始碼與編譯產物的 `mtime`。這是最快速的檢查，但依賴於檔案系統的奈秒級精度。
2.  **指紋雜湊比對 (Fingerprint Hash)**：若 `mtime` 檢查未通過或不明確，Cargo 會計算編譯單元 (Compilation Unit) 的指紋雜湊。該雜湊不僅包含原始碼內容，還隱性包含了編譯器版本、RUSTFLAGS 以及**絕對路徑**。

此外，Rust 編譯器 `rustc` 會產生 `.d` (dep-info) 檔案，其中詳列了該 Crate 的所有依賴檔案路徑。若這些路徑為絕對路徑且與當前環境不符，將導致 Cargo 判定環境「髒污 (Dirty)」而觸發重編。

### 3.2 現有的快取解決方案
*   **sccache (Mozilla)**：透過包裝 rustc 編譯器，將編譯產物快取至本機或雲端儲存（S3/GCS）。其優點是跨機器共享，但缺點是不支援所有的 Rust 編譯參數（如連結階段），且網路傳輸可能成為瓶頸。
*   **Docker Layer Caching**：利用 OverlayFS 分層儲存。雖然能重用層（Layer），但層的唯讀特性不適合頻繁寫入的增量編譯環境。

### 3.3 Btrfs 與 Reflink 技術
Btrfs 是一種支援 CoW 的先進檔案系統。其 `FICLONE` ioctl 允許使用者建立檔案的「淺層複製」（Reflink）。這兩個檔案共享硬碟上的同一個物理區塊（Extent），直到其中一方被寫入修改時，才分離出新的區塊。這使得複製 GB 級的目錄只需修改 Metadata，耗時僅需毫秒級。

## (四) 研究方法及步驟

### 4.1 系統架構設計
本研究設計了一套自動化腳本架構，包含以下流程：
1.  **基準快照建立**：對主分支進行一次完整編譯，產出「黃金映像」（Golden Image）的 `target` 目錄。
2.  **Worktree 初始化**：使用 `git worktree add` 建立新開發環境。
3.  **快取注入 (Cache Injection)**：使用 `cp --reflink=always` 將黃金映像的 `target` 複製到新 Worktree 中。
4.  **Metadata 修正**：遞迴修正檔案的 `mtime`，嘗試騙過 Cargo 的新鮮度檢查。

### 4.2 實驗環境
*   **作業系統**: Arch Linux (Kernel 6.x)
*   **檔案系統**: Btrfs (Mount options: `compress=zstd:3, noatime`)
*   **硬體**: NVMe SSD
*   **測試專案**:
    *   小型專案：`ripgrep` (純 Rust)
    *   大型專案：`Zed` (Rust + C/C++ FFI)

### 4.3 評估指標與工具
1.  **時間效率**：使用 `hyperfine` 進行多次運行的統計顯著性測試 (Warmup: 3, Runs: 10)，並利用 `cargo --timings` 產生的甘特圖分析編譯管線中的瓶頸（如 Codegen Unit 併發度或連結階段）。
2.  **空間效率**：使用 `compsize` 工具測量 Btrfs 檔案系統上的實際磁碟佔用量（Disk Usage）與邏輯大小（Referenced）的差異，以量化 Reflink 與 Zstd 的壓縮效益。

## (五) 實驗結果

### 5.1 建置時間效能 (Build Time Performance)

#### 表 1：冷啟動 (Cold Start) 效能比較
| 專案規模 | 傳統全量編譯 | Reflink 快照還原 | 加速倍率 | 結果判讀 |
| :--- | :--- | :--- | :--- | :--- |
| **ripgrep** (小) | 4.09 s | **2.80 s** | **1.46x** | **有效**。Reflink 成功省去相依套件編譯時間。 |
| **Zed** (大) | 140.8 s | 146.1 s | **0.96x** | **失效**。複製開銷大於收益，且快取大量失效。 |

#### 表 2：增量編譯 (Incremental) 效能比較
| 專案規模 | 原生增量編譯 | Reflink + 增量 | 效能落差 | 結果判讀 |
| :--- | :--- | :--- | :--- | :--- |
| **ripgrep** | **0.67 s** | 5.37 s | **慢 8.0x** | 檔案系統操作固定開銷過大。 |

### 5.2 磁碟空間效率 (Disk Space Efficiency)
在 `ripgrep` 的多分支測試中：
*   **邏輯大小**: 1.6 GB (若不使用 CoW)
*   **物理大小**: **372 MB** (使用 CoW + Zstd)
*   **空間節省率**: **77%**

數據證實，Reflink 配合 Zstd 壓縮能以極低的成本維護多個獨立的建置環境。

## (六) 分析與討論

### 6.1 固定開銷與適用邊界
實驗揭示了本架構存在約 **2.5 秒** 的固定開銷（來自 `cp --reflink` 與 Metadata 掃描）。這定義了技術的「黃金交叉點」：僅當專案的 Clean Build 時間顯著大於 30 秒時，Reflink 帶來的冷啟動優勢才會超過其開銷。對於日常修改單一檔案的「存檔-編譯」循環（Inner Loop），原生 Cargo 增量編譯仍是最佳解。

### 6.2 路徑污染與連結器瓶頸 (The Linker Bottleneck)
在 `Zed` 專案的實驗失敗，揭示了兩個深層問題：

1.  **Dep-info 的絕對路徑陷阱**：Cargo 依賴 `target/debug/*.d` (dep-info) 檔案來追蹤依賴關係。實驗發現，即使原始碼未變動，若這些檔案中紀錄了舊 Worktree 的絕對路徑，Cargo 會判定依賴遺失或路徑不匹配，強制觸發全量重編。
2.  **連結器 (Linker) 無法快取**：對於大型專案，增量編譯的瓶頸往往不在 `rustc`，而在連結階段 (`ld` 或 `lld`)。連結器必須將成千上萬個 Object Files 合併為最終執行檔。由於連結器對輸入檔案路徑極度敏感，且缺乏類似 sccache 的快取機制，一旦上游路徑改變，整個連結過程必須重來，導致即使是極小的修改也需要數十秒的「連結懲罰 (Linking Penalty)」。

### 6.3 空間換取時間的策略
儘管在大型專案的編譯加速上受阻，但 **77% 的空間節省** 是無條件的紅利。這對於資源受限的筆記型電腦開發者而言極具價值，允許同時保留多個 Feature Branch 的建置狀態，隨時切換進行 Debug 而無需清空 `target` 釋放空間。

## (七) 結論及未來研究方向

### 7.1 結論
本研究證實了利用 Btrfs Reflink 優化 Rust 開發流程在「空間效率」上具有巨大優勢，但在「編譯效能」上受限於專案規模與路徑依賴性。
*   對於**純 Rust 中小型專案**，本方案能有效加速分支切換後的首次建置。
*   對於**大型混合語言專案**，單純的檔案系統操作無法騙過編譯器的路徑檢查，導致快取失效。

### 7.2 未來研究方向
為了解決路徑污染問題，建議採納以下兩種策略：

1.  **短期策略：容器化虛擬路徑 (Containerized Path Virtualization)**
    利用 Linux Namespaces (如 Bubblewrap 或 Docker)，將不同的 Git Worktree 掛載到容器內的**固定路徑** (例如 `/app`)。對 Cargo 而言，所有建置操作永遠發生在 `/app`，徹底騙過路徑指紋檢查。結合 Reflink 在宿主機 (Host) 層面的儲存優勢，可達成完美的增量編譯快取重用。

2.  **長期策略：追蹤 Rust RFC 3127 (trim-paths)**
    Rust 社群已意識到絕對路徑對可重現建置 (Reproducible Builds) 的危害。RFC 3127 提案引入 `--trim-paths` 編譯參數，旨在從二進位檔與除錯資訊中徹底移除絕對路徑。待此功能穩定後，Reflink 方案將不再依賴容器化即可在本地運作，大幅降低使用門檻。

## (八) 參考文獻

1.  Btrfs Documentation. (n.d.). *Copy on Write (CoW)*. https://btrfs.wiki.kernel.org/
2.  The Cargo Book. (n.d.). *Build Cache & Fingerprinting*.
3.  Mozilla. (n.d.). *sccache - Shared Cloud Cache for Rust*.
4.  Levoon, A. (2023). *Optimizing Rust Build Times with Reflinks* (Internal Experiment Report).
5.  Matsakis, N. (2016). *Rust Incremental Compilation*. Rust Blog.