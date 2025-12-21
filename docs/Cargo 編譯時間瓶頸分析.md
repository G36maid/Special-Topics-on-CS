# **Rust 編譯管線效能最佳化報告：系統級 CoW 快取與專案級快照策略之深度比較分析**

## **摘要**

本研究報告針對 Cargo 建置系統的內部機制進行了詳盡的解構與分析，旨在解決 Rust 專案在大型開發規模下日益嚴重的編譯延遲問題。研究的核心目標在於釐清 target 目錄下各個子結構（deps、incremental、.fingerprint）在編譯時間中的佔比與行為特徵，並據此評估兩種主要最佳化策略：「System-wide CoW Cache（系統級寫入時複製快取）」與「Project-level Snapshots（專案級快照）」的適用性。  
分析顯示，雖然相依性編譯（deps）在「冷建置（Cold Build）」中佔據了主要時間，但在開發者最常面對的「增量建置（Incremental Build）」循環中，效能瓶頸已顯著轉移至\*\*連結階段（Linking）**以及**增量狀態追蹤（Dependency Tracking）\*\*的開銷。透過 cargo build \--timings 與 \-Z self-profile 等工具的測量數據表明，在增量編譯場景下，連結時間可能佔據高達 40% 至 90% 的等待時間。  
針對策略選擇，本報告提出結論：\*\*系統級 CoW 快取（如 sccache）\*\*雖能有效減少磁碟佔用並加速 CI 環境下的冷建置，但由於其必須停用 rustc 的增量編譯功能，且無法緩解連結瓶頸，因此不適合用於本地開發的「編輯-編譯-測試」循環。相對地，**專案級快照策略（Project-level Snapshots）**——結合 Git Worktrees 與檔案系統（如 Btrfs/APFS）的 Reflink 技術——能夠完整保留 incremental 目錄下的查詢快取（Query Cache）與 mtime 指紋，有效避免了切換分支時的冗餘重建。  
本報告建議採用一種**混合式架構**：利用檔案系統層級的 Reflink 來快速複製 deps 以節省空間，同時利用獨立的 Worktree 目錄來隔離 incremental 狀態，並強制搭配高效能連結器（如 Mold）以解決最終的連結瓶頸。

## ---

**1\. 緒論：Rust 編譯時間的結構性挑戰**

Rust 語言的設計哲學傾向於將執行時期的負擔轉移至編譯時期。借用檢查（Borrow Checking）、單型化（Monomorphization）以及積極的 LLVM 優化，造就了 Rust 執行效能的卓越，但也導致了編譯時間（Compile Time）成為開發者體驗中最大的痛點 1。  
對於開發者而言，編譯時間並非單一的指標，而是由不同的工作負載組成的複雜總和。當開發者詢問「為什麼我的構建這麼慢？」時，答案往往隱藏在 cargo 與 rustc 如何管理 target 目錄下的中間產物（Intermediate Artifacts）。為了制定有效的快取策略，我們必須深入剖析編譯過程的解剖學結構。

### **1.1 研究目標與範圍**

本研究聚焦於以下三個關鍵問題：

1. **測量方法學**：如何精確量化編譯過程中各個階段（前端分析、後端程式碼生成、連結）的時間消耗？  
2. **時間分佈特徵**：在 target 目錄的結構中，deps（相依性）、incremental（增量狀態）與最終的 Linking（連結）在不同情境下的時間佔比為何？  
3. **策略效能評估**：在「系統級 CoW 快取」與「專案級快照」之間，哪一種策略能最大程度地解決上述的效能瓶頸？

### **1.2 target 目錄的解剖學**

target 目錄是 Cargo 建置過程的狀態機。理解其子目錄的功能與揮發性（Volatility）是優化的前提 3。

* **target/debug/deps/**：存放外部依賴（Dependencies）的編譯產物（.rlib, .rmeta, .so）。這些檔案具有高度的穩定性，僅在 Cargo.lock 變更或編譯器版本更新時才會改變。它們佔據了冷建置的大部分時間。  
* **target/debug/incremental/**：存放 rustc 的增量編譯狀態。這是一個極度複雜且脆弱的結構，包含了相依性圖（Dependency Graph）、查詢系統快取（Query Cache）與序列化的 AST/MIR。這些數據與原始碼的檔案路徑及修改時間（mtime）緊密綁定，極易失效。  
* **target/debug/.fingerprint/**：Cargo 的簿記系統。這些微小的檔案記錄了每個編譯單元（Unit）的雜湊值（Hash）與時間戳記（Timestamp）。Cargo 依賴這些指紋來決定是否觸發 rustc 的調用 4。

## ---

**2\. 編譯時間測量方法學 (Metrology of Compilation)**

要優化編譯速度，首先必須具備觀測能力。Rust 生態系統提供了多層次的分析工具，從高階的 Cargo 流程到低階的編譯器查詢與系統呼叫。

### **2.1 高階流程分析：Cargo Timings**

cargo build \--timings 是分析建置管線最直觀的工具。它會生成一份 HTML 報告，視覺化地呈現每個 Crate 的編譯時間與並行狀態 6。

#### **2.1.1 解讀 Timings 報告**

報告中包含兩個關鍵圖表：

1. **單元圖（Unit Graph）**：顯示每個 Crate 的編譯長度。  
   * **淡紫色長條（Lavender Bars）**：代表 **Codegen（程式碼生成）** 階段。如果某個 Crate 的紫色部分極長，表示該 Crate 包含大量泛型或複雜的邏輯，導致 LLVM 後端處理緩慢 6。  
   * **依賴鏈（Critical Path）**：透過滑鼠懸停，可以觀察到哪些 Crate 阻塞了後續的編譯。這有助於識別是否因為某個巨大的基礎庫（如 syn 或 serde）導致了並行度下降。  
2. **並行度圖（Concurrency Graph）**：顯示 CPU 的利用率。  
   * **紅色線（Waiting）**：表示有多少單元在等待 CPU 資源。  
   * **藍色線（Inactive）**：表示有多少單元在等待依賴項完成。  
   * **綠色線（Active）**：表示正在運行的編譯任務。

**關鍵洞察**：在增量編譯的報告末尾，若出現一段長時間的單一執行緒活動（通常伴隨著極低的 CPU 利用率），這幾乎總是代表**連結階段（Linking）**。這是傳統編譯器分析容易忽略的盲點 6。

### **2.2 編譯器內部剖析：Self-Profile**

對於需要深入了解 rustc 內部行為的場景，-Z self-profile 提供了細粒度的數據 1。

#### **2.2.1 設定與執行**

由於此功能屬於不穩定特性，通常需要 Nightly 工具鏈，但近期版本已逐漸在 Stable 中開放部分功能。

Bash

RUSTFLAGS="-Z self-profile" cargo build

此指令會在工作目錄下生成 .mm\_profdata 檔案。

#### **2.2.2 數據分析工具**

使用 measureme 工具集進行分析：

* **summarize**：提供文字摘要，列出最耗時的編譯階段。  
  * expand\_crate：巨集展開時間。若此數值過高，表示過度使用 proc-macro 9。  
  * LLVM\_passes / codegen\_module：LLVM 優化與生成時間。這通常與優化等級（opt-level）與泛型數量正相關。  
  * link\_binary：明確的連結時間 10。  
* **crox**：將數據轉換為 Chrome Tracing 格式 (chrome\_profiler.json)，可載入 Chrome 瀏覽器的 chrome://tracing 介面，以火焰圖（Flamegraph）形式檢視每個查詢（Query）的執行時間與相依關係 8。

### **2.3 系統級效能基準測試：Hyperfine**

為了評估不同快取策略（如 CoW Cache vs Snapshots）對「牆鐘時間（Wall-clock Time）」的真實影響，hyperfine 是業界標準的統計性基準測試工具 11。  
**測試腳本範例**：

Bash

\# 基準測試：模擬修改檔案後的增量編譯  
hyperfine \--warmup 1 \--prepare 'touch src/main.rs' 'cargo build'

透過自動化的多次執行與離群值剔除，hyperfine 能消除磁碟快取與背景程序對測試結果的干擾，提供可信的策略比較數據 13。

## ---

**3\. 編譯時間佔比分析：從冷建置到增量建置**

Rust 的編譯時間分佈並非一成不變，它隨著建置情境（Context）的變化而有劇烈的結構性轉移。

### **3.1 冷建置（Cold Build）：依賴編譯的絕對主導**

在全新的環境（如 CI Server 或新克隆的 Repo）中進行首次建置時，時間成本幾乎完全由\*\*相依性編譯（deps）\*\*主導。

* **數據支撐**：編譯如 ripgrep 這樣的中型專案，可能需要編譯 70+ 個依賴套件。在現代多核 CPU 上，這部分的並行度很高，但總 CPU 時間極大。數據顯示，在冷建置中，deps 的編譯時間通常佔總時間的 **85% \- 95%** 14。  
* **瓶頸分析**：此階段的主要瓶頸是 **CPU 吞吐量** 與 **磁碟寫入 I/O**。由於每個依賴都是獨立的 Crate，編譯器必須為每個 Crate 生成 metadata 與 object files。  
* **快取機會**：這是「System-wide CoW Cache」發揮最大效益的戰場。由於依賴套件的版本與內容是鎖定的（Immutable），一旦在系統中某處被編譯過，理論上所有專案皆可共享。

### **3.2 增量建置（Incremental Build）：連結器的懸崖**

當開發者進入「修改-編譯」的循環（Inner Loop）時，情勢發生逆轉。此時 deps 已經編譯完成並被 Cargo 快取，時間分佈呈現出截然不同的樣貌。

1. **Cargo 指紋檢查（\< 1s）**：Cargo 掃描 .fingerprint 與 dep-info，確認哪些 Crate 需要重建。  
2. **增量編譯前端（Frontend）**：rustc 載入 incremental/ 中的 dep-graph，比對查詢雜湊值。若只修改了函式本體（Function Body），前端分析極快。  
3. **增量編譯後端（Codegen）**：僅重新生成受影響的 Codegen Units（CGUs）。  
4. **連結（Linking）**：**這是真正的殺手**。  
* **數據支撐**：多項研究與社群回報指出，在增量建置中，**連結時間（Linking Time）** 往往佔據了 **40% 至 90%** 的總等待時間 13。  
* **原因分析**：預設的連結器（如 GNU ld 或 macOS ld64）在處理大型二進位檔時，通常是單執行緒運作的。即使只修改了一行程式碼，連結器仍需重新讀取所有依賴的 .rlib 與 .o 檔，解析符號表，並寫入數百 MB 甚至 GB 的執行檔。這是一個序列化的過程，無法受益於多核 CPU 7。  
* **隱形瓶頸**：許多開發者誤以為編譯慢是因為 Rust 語言本身，但實際上他們等待的是連結器將數千個符號重新組裝的時間。

### **3.3 增量狀態失效的代價**

若 incremental/ 目錄下的狀態因故失效（例如切換 Git 分支導致 mtime 變更），rustc 將被迫放棄增量優化，退化為該 Crate 的全量編譯。這會導致「增量建置」退化為「局部冷建置」，時間成本增加 3 至 10 倍 20。

## ---

**4\. 策略分析 A：System-wide CoW Cache (系統級寫入時複製快取)**

此策略的核心概念是建立一個全域的、跨專案的建置產物儲存庫，並利用 Copy-on-Write 技術來減少磁碟消耗。典型的實作工具是 sccache 或共用 CARGO\_TARGET\_DIR。

### **4.1 機制與實作**

* **sccache**：這是一個編譯器包裝器（Compiler Wrapper）。它攔截 rustc 的調用，將輸入參數與原始碼雜湊後作為 Key，查詢遠端或本地的快取。如果命中，直接下載產物；否則執行編譯並上傳結果 22。  
* **共用 CARGO\_TARGET\_DIR**：將環境變數 CARGO\_TARGET\_DIR 設定為一個全域路徑（如 \~/.cargo/target\_cache），迫使所有專案輸出到同一目錄 24。

### **4.2 優勢分析**

1. **依賴編譯的極致優化**：對於 deps 結構，此策略效果顯著。serde、tokio 等通用庫只需在系統中編譯一次，所有專案皆可受益。這能大幅縮短新專案的初始化時間 23。  
2. **磁碟空間節省**：透過 Deduplication（去重複化），避免了每個專案目錄下都存放一份相同的數百 MB 依賴檔 25。

### **4.3 致命缺陷：增量編譯與連結的互斥性**

然而，針對本研究關注的「增量建置」效能，系統級快取存在嚴重的結構性缺陷。

#### **4.3.1 增量編譯的失效**

sccache 目前**明確不支援** Rust 的增量編譯功能 22。

* **原因**：Rust 的增量編譯依賴於複雜的本地檔案系統狀態（incremental/ 目錄下的 dep-graph）。要正確快取這些狀態，需要對整個目錄結構進行雜湊，這在計算上極其昂貴且難以保證跨機器的一致性。  
* **後果**：啟用 sccache 會強制關閉 incremental=true。這意味著，雖然你加速了依賴編譯，但對於你自己正在開發的 Crate，每次修改都會觸發該 Crate 的全量編譯。這直接違背了優化「Inner Loop」的目標，甚至可能導致開發時的編譯變慢 28。

#### **4.3.2 連結階段無法快取**

sccache 快取的是編譯產物（Object Files, .rlib），而非最終的二進位執行檔。因此，它**完全無法解決連結（Linking）的瓶頸**。無論快取命中率多高，連結器仍需在本地執行，消耗大量的 I/O 與 CPU 時間 30。

#### **4.3.3 鎖定（Locking）地獄**

若採用共用 CARGO\_TARGET\_DIR 策略，Cargo 會對該目錄實施全域檔案鎖。這意味著你無法同時編譯兩個不同的專案，甚至無法在執行 cargo run 的同時讓 IDE（如 Rust Analyzer）在背景執行 cargo check。這種序列化限制嚴重影響多工開發流程 32。

### **4.4 結論**

系統級快取是 **CI/CD 環境** 的最佳解，但在本地開發環境中，它犧牲了增量編譯能力與並行性，無法解決最關鍵的連結瓶頸。

## ---

**5\. 策略分析 B：Project-level Snapshots (專案級快照)**

此策略利用現代檔案系統（Btrfs, ZFS, APFS）的快照與 Reflink 功能，或 Git Worktree 機制，為每個開發分支維護獨立但共享數據的 target 目錄。

### **5.1 機制與實作**

* **Git Worktrees**：不使用 git checkout 切換分支，而是為每個分支建立獨立的工作目錄（Worktree）。每個 Worktree 擁有獨立的 target 目錄。  
* **檔案系統快照/Reflink**：在建立新 Worktree 時，不進行空目錄初始化，而是使用 cp \--reflink=always 從主分支的 target 目錄複製一份副本 35。  
  * **CoW 特性**：Reflink 複製在物理磁碟上不佔用額外空間，僅複製 metadata（Inode 指標）。只有當新分支的編譯產生差異時，才會寫入新的數據塊（Blocks）。

### **5.2 對 incremental 結構的優勢**

這是本策略的核心價值所在。它完美解決了 Cargo 指紋（Fingerprint）的脆弱性問題。

#### **5.2.1 mtime 與指紋保護**

Cargo 預設使用檔案修改時間（mtime）來判斷編譯單元是否過期 4。

* **切換分支的災難**：在單一工作目錄下使用 git checkout 切換分支時，Git 會更新原始碼檔案的 mtime。這會欺騙 Cargo，使其認為檔案已變更（即使內容雜湊值相同），進而觸發不必要的重建 20。更甚者，incremental/ 目錄下的 dep-graph 是針對舊分支的程式碼生成的，新分支的程式碼會導致圖形不匹配，迫使 rustc 拋棄整個增量快取 37。  
* **快照的解決方案**：每個 Worktree 擁有獨立的 target。當你切換目錄時，該目錄下的 incremental 狀態與原始碼是完全同步且未被觸碰的。Cargo 檢查 mtime 發現未變更，直接回傳 "Fresh"，編譯時間為 **0秒**。

#### **5.2.2 查詢快取（Query Cache）的保存**

rustc 的紅綠演算法（Red-Green Algorithm）依賴於前次編譯的查詢結果。專案級快照確保了每個分支都有自己專屬的「綠色節點」歷史紀錄。這使得在不同功能分支間頻繁切換（Context Switching）時，無需承受任何編譯懲罰 39。

### **5.3 對 deps 與 linking 的影響**

* **Deps**：透過 cp \--reflink 初始化新 Worktree，新分支繼承了主分支所有已編譯的 deps。這達到了與系統級快取相同的「只編譯一次」效果，且無需額外的磁碟空間 36。  
* **Linking**：雖然快照本身不加速連結器，但它避免了不必要的重新連結。更重要的是，它允許開發者針對特定分支進行 mold 等高速連結器的配置，而不受全域設定影響。

### **5.4 結論**

專案級快照策略透過物理隔離解決了 mtime 失效與鎖定衝突問題，並透過 Reflink 解決了磁碟空間問題。它是針對「開發者體驗（DX）」的最佳化方案。

## ---

**6\. 綜合比較與瓶頸解決方案**

基於上述分析，我們將兩種策略針對不同指標進行對比，並引入能解決最大瓶頸（連結）的關鍵技術。

### **6.1 策略效能矩陣**

| 評估指標 | 系統級 CoW 快取 (System-wide Cache) | 專案級快照 (Project-level Snapshots) |
| :---- | :---- | :---- |
| **依賴編譯 (Deps) 速度** | **極快** (全域共享，一次編譯) | **極快** (若使用 Reflink 初始化) |
| **增量編譯 (Incremental) 支援** | **無** (必須停用，導致變慢) | **完美** (完整保留 dep-graph) |
| **分支切換成本 (Branch Switching)** | **高** (需重建，因 mtime/指紋失效) | **零** (狀態隔離且持久化) |
| **磁碟空間效率** | **高** (去重複化) | **中高** (依賴 CoW 檔案系統) |
| **並行編譯能力** | **低** (全域鎖定衝突) | **高** (目錄隔離，無鎖定問題) |
| **主要適用場景** | CI/CD流水線、唯讀依賴管理 | 本地高頻開發、多分支作業 |

### **6.2 解決最大效能瓶頸：連結器 (The Linker)**

如前所述，無論採用何種快取策略，都無法消除增量編譯中的**連結時間**。這是物理上的瓶頸。要解決此問題，必須更換連結器。

* **Mold / Sold**：現代化的高效能連結器，專為多核架構設計。  
  * **效能數據**：在 Linux 上，mold 的連結速度比預設的 ld 快 **5 到 10 倍**。對於大型 Rust 專案，這能將連結時間從 20 秒縮短至 2 秒 13。  
  * **整合方式**：配合專案級快照，可以在 .cargo/config.toml 中為特定專案啟用 mold，獲得立竿見影的提速。

### **6.3 推薦架構：混合式工作流**

為了同時解決「依賴編譯」、「增量狀態保存」與「連結瓶頸」，本報告提出以下最佳實踐架構：

1. **檔案系統層**：使用支援 Reflink 的檔案系統（Linux 上的 Btrfs/XFS，macOS 上的 APFS）。  
2. **工作區管理**：採用 **Git Worktrees** 搭配 **Reflink Seed**。  
   * 不使用 git checkout。  
   * 建立新功能分支時：  
     Bash  
     git worktree add../feature-branch feature-branch  
     cp \-r \--reflink=always main/target../feature-branch/

   * 此操作瞬間完成，新分支立即擁有熱騰騰的 deps 與 incremental 狀態。  
3. **編譯器配置**：配置使用 mold 連結器。  
   * 在 .cargo/config.toml 中：  
     Ini, TOML  
     \[target.x86\_64-unknown-linux-gnu\]  
     linker \= "clang"  
     rustflags \= \["-C", "link-arg=-fuse-ld=mold"\]

4. **清理策略**：利用 cargo-sweep 定期清理過期的 Reflink 副本，而非依賴全域快取的自動回收 42。

## ---

**7\. 結論**

Rust 編譯效能的最佳化是一場針對「狀態管理」的博弈。調查結果顯示，target 目錄下的 incremental 結構是開發者時間資產中最寶貴的部分，其價值遠高於易於重建的 deps。  
**「System-wide CoW Cache」** 雖然在架構上優雅且節省空間，但其對增量編譯的破壞性使其成為本地開發的次佳選擇。它解決了「冷建置」的問題，卻惡化了開發者每天重複數百次的「熱建置」。  
**「Project-level Snapshots」** 策略，特別是結合了 Git Worktrees 與 Btrfs/Reflink 技術後，能夠在隔離性與效率之間取得最佳平衡。它保護了脆弱的 mtime 指紋與查詢快取，消除了切換上下文時的重建成本。配合 **Mold** 連結器的引入，此組合能精確打擊 Rust 編譯流程中最大的兩個痛點：增量失效與連結延遲。  
因此，對於追求極致迭代速度的專業 Rust 開發團隊，採用 **專案級快照 \+ Reflink \+ Mold** 是目前技術條件下的最佳解方。

### ---

**表 1：編譯階段時間佔比與優化策略對照表**

| 編譯階段 | 典型時間佔比 (冷建置) | 典型時間佔比 (增量建置) | 最佳化策略 | 備註 |
| :---- | :---- | :---- | :---- | :---- |
| **相依性 (Deps)** | **85% \- 95%** | 0% (Cached) | Reflink 複製 / sccache | 冷建置主要瓶頸 |
| **前端分析 (Front)** | 5% \- 10% | 5% \- 10% | 增量編譯 (Project Snapshot) | 需保留 dep-graph |
| **後端生成 (Codegen)** | 5% \- 10% | 10% \- 30% | 並行 Codegen / 增量編譯 | 受 CPU 核數影響 |
| **連結 (Linking)** | 1% \- 5% | **40% \- 90%** | **Mold / LLD 連結器** | **增量建置最大瓶頸** |

1

#### **引用的著作**

1. What part of Rust compilation is the bottleneck? \- Kobzol's blog, 檢索日期：12月 17, 2025， [https://kobzol.github.io/rust/rustc/2024/03/15/rustc-what-takes-so-long.html](https://kobzol.github.io/rust/rustc/2024/03/15/rustc-what-takes-so-long.html)  
2. 8 Solutions for Troubleshooting Your Rust Build Times | by Dotan Nahum \- Medium, 檢索日期：12月 17, 2025， [https://jondot.medium.com/8-steps-for-troubleshooting-your-rust-build-times-2ffc965fd13e](https://jondot.medium.com/8-steps-for-troubleshooting-your-rust-build-times-2ffc965fd13e)  
3. Build Cache \- The Cargo Book \- Rust Documentation, 檢索日期：12月 17, 2025， [https://doc.rust-lang.org/cargo/reference/build-cache.html](https://doc.rust-lang.org/cargo/reference/build-cache.html)  
4. Module fingerprint \- cargo::core::compiler \- Rust Documentation, 檢索日期：12月 17, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html)  
5. cargo/core/compiler/fingerprint/ mod.rs \- Docs.rs, 檢索日期：12月 17, 2025， [https://docs.rs/cargo/latest/src/cargo/core/compiler/fingerprint/mod.rs.html](https://docs.rs/cargo/latest/src/cargo/core/compiler/fingerprint/mod.rs.html)  
6. Reporting build timings \- The Cargo Book, 檢索日期：12月 17, 2025， [https://doc.rust-lang.org/cargo/reference/timings.html](https://doc.rust-lang.org/cargo/reference/timings.html)  
7. Why is the linker fast and slow during the same build? : r/rust \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/117iryo/why\_is\_the\_linker\_fast\_and\_slow\_during\_the\_same/](https://www.reddit.com/r/rust/comments/117iryo/why_is_the_linker_fast_and_slow_during_the_same/)  
8. Intro to rustc's self profiler | Inside Rust Blog, 檢索日期：12月 17, 2025， [https://blog.rust-lang.org/inside-rust/2020/02/25/intro-rustc-self-profile.html](https://blog.rust-lang.org/inside-rust/2020/02/25/intro-rustc-self-profile.html)  
9. Compilation time profiling tool? : r/rust \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/akwm3z/compilation\_time\_profiling\_tool/](https://www.reddit.com/r/rust/comments/akwm3z/compilation_time_profiling_tool/)  
10. Linking taking an inordinately long time \- help \- The Rust Programming Language Forum, 檢索日期：12月 17, 2025， [https://users.rust-lang.org/t/linking-taking-an-inordinately-long-time/39253](https://users.rust-lang.org/t/linking-taking-an-inordinately-long-time/39253)  
11. Benchmarking and Profiling \- Cargo Contributor Guide, 檢索日期：12月 17, 2025， [https://doc.crates.io/contrib/tests/profiling.html](https://doc.crates.io/contrib/tests/profiling.html)  
12. sharkdp/hyperfine: A command-line benchmarking tool \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/sharkdp/hyperfine](https://github.com/sharkdp/hyperfine)  
13. How I Improved My Rust Compile Times by 75% \- benwis, 檢索日期：12月 17, 2025， [https://benw.is/posts/how-i-improved-my-rust-compile-times-by-seventy-five-percent](https://benw.is/posts/how-i-improved-my-rust-compile-times-by-seventy-five-percent)  
14. Exploring the Rust compiler benchmark suite \- Kobzol's blog, 檢索日期：12月 17, 2025， [https://kobzol.github.io/rust/rustc/2023/08/18/rustc-benchmark-suite.html](https://kobzol.github.io/rust/rustc/2023/08/18/rustc-benchmark-suite.html)  
15. The Rust Compilation Model Calamity | by TiDB \- Medium, 檢索日期：12月 17, 2025， [https://pingcap.medium.com/the-rust-compilation-model-calamity-1a8ce781cf6c](https://pingcap.medium.com/the-rust-compilation-model-calamity-1a8ce781cf6c)  
16. Dynamic linking for compilation speed improvement? \- Rust Internals, 檢索日期：12月 17, 2025， [https://internals.rust-lang.org/t/dynamic-linking-for-compilation-speed-improvement/13493](https://internals.rust-lang.org/t/dynamic-linking-for-compilation-speed-improvement/13493)  
17. how are Rust compile times vs those on C++ on "bigger" projects? \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/1kc37m8/how\_are\_rust\_compile\_times\_vs\_those\_on\_c\_on/](https://www.reddit.com/r/rust/comments/1kc37m8/how_are_rust_compile_times_vs_those_on_c_on/)  
18. Linking \- Rust Project Primer, 檢索日期：12月 17, 2025， [https://rustprojectprimer.com/building/linker.html](https://rustprojectprimer.com/building/linker.html)  
19. Building a computer for fastest possible Rust compile times \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/chqu4c/building\_a\_computer\_for\_fastest\_possible\_rust/](https://www.reddit.com/r/rust/comments/chqu4c/building_a_computer_for_fastest_possible_rust/)  
20. (Option to) Fingerprint by file contents instead of mtime · Issue \#6529 · rust-lang/cargo, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/6529](https://github.com/rust-lang/cargo/issues/6529)  
21. Fast Rust Builds \- matklad, 檢索日期：12月 17, 2025， [https://matklad.github.io/2021/09/04/fast-rust-builds.html](https://matklad.github.io/2021/09/04/fast-rust-builds.html)  
22. mozilla/sccache: Sccache is a ccache-like tool. It is used as a compiler wrapper and avoids compilation when possible. Sccache has the capability to utilize caching in remote storage environments, including various cloud storage options, or alternatively, in local storage. \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/mozilla/sccache](https://github.com/mozilla/sccache)  
23. sccache is pretty okay \- rtyler, 檢索日期：12月 17, 2025， [https://brokenco.de/2025/08/25/sccache-is-pretty-okay.html](https://brokenco.de/2025/08/25/sccache-is-pretty-okay.html)  
24. Setting a base target directory \- cargo \- Rust Internals, 檢索日期：12月 17, 2025， [https://internals.rust-lang.org/t/setting-a-base-target-directory/12713](https://internals.rust-lang.org/t/setting-a-base-target-directory/12713)  
25. Is there a way to make the size of whole project files smaller? \- Rust Users Forum, 檢索日期：12月 17, 2025， [https://users.rust-lang.org/t/is-there-a-way-to-make-the-size-of-whole-project-files-smaller/100758](https://users.rust-lang.org/t/is-there-a-way-to-make-the-size-of-whole-project-files-smaller/100758)  
26. PSA: Run \`cargo clean\` on old projects you don't intend to build again. : r/rust \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/cbc24k/psa\_run\_cargo\_clean\_on\_old\_projects\_you\_dont/](https://www.reddit.com/r/rust/comments/cbc24k/psa_run_cargo_clean_on_old_projects_you_dont/)  
27. Sccache for caching Rust compilation \- announcements, 檢索日期：12月 17, 2025， [https://users.rust-lang.org/t/sccache-for-caching-rust-compilation/10960](https://users.rust-lang.org/t/sccache-for-caching-rust-compilation/10960)  
28. Local disk cache 3-4.5x slower than ccache · Issue \#160 · mozilla/sccache \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/mozilla/sccache/issues/160](https://github.com/mozilla/sccache/issues/160)  
29. Does sccache really help? : r/rust \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/rvqxkf/does\_sccache\_really\_help/](https://www.reddit.com/r/rust/comments/rvqxkf/does_sccache_really_help/)  
30. I prefer external caching/distributed solutions like ccache/sccache/sndbs than t... | Hacker News, 檢索日期：12月 17, 2025， [https://news.ycombinator.com/item?id=13044838](https://news.ycombinator.com/item?id=13044838)  
31. Why You Need Sccache \- Elijah Potter, 檢索日期：12月 17, 2025， [https://elijahpotter.dev/articles/why\_you\_need\_sccache](https://elijahpotter.dev/articles/why_you_need_sccache)  
32. Target directory isolation/locking fails when cross-compiling · Issue \#5968 · rust-lang/cargo, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/5968](https://github.com/rust-lang/cargo/issues/5968)  
33. Avoiding locking issues / finding build artifacts \- help \- Rust Users Forum, 檢索日期：12月 17, 2025， [https://users.rust-lang.org/t/avoiding-locking-issues-finding-build-artifacts/121578](https://users.rust-lang.org/t/avoiding-locking-issues-finding-build-artifacts/121578)  
34. cargo always starts with " Blocking waiting for file lock on build directory" \- Stack Overflow, 檢索日期：12月 17, 2025， [https://stackoverflow.com/questions/39335774/cargo-always-starts-with-blocking-waiting-for-file-lock-on-build-directory](https://stackoverflow.com/questions/39335774/cargo-always-starts-with-blocking-waiting-for-file-lock-on-build-directory)  
35. In my own case: Btrfs performance got absolutely terrible once I was up to a few... \- Hacker News, 檢索日期：12月 17, 2025， [https://news.ycombinator.com/item?id=36694970](https://news.ycombinator.com/item?id=36694970)  
36. Reflink — BTRFS documentation \- Read the Docs, 檢索日期：12月 17, 2025， [https://btrfs.readthedocs.io/en/latest/Reflink.html](https://btrfs.readthedocs.io/en/latest/Reflink.html)  
37. Suggested workflows \- Rust Compiler Development Guide, 檢索日期：12月 17, 2025， [https://rustc-dev-guide.rust-lang.org/building/suggested.html?highlight=worktree](https://rustc-dev-guide.rust-lang.org/building/suggested.html?highlight=worktree)  
38. Incremental compilation of cargo fails \- help \- The Rust Programming Language Forum, 檢索日期：12月 17, 2025， [https://users.rust-lang.org/t/incremental-compilation-of-cargo-fails/97889](https://users.rust-lang.org/t/incremental-compilation-of-cargo-fails/97889)  
39. Incremental compilation \- Rust Compiler Development Guide, 檢索日期：12月 17, 2025， [https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation.html](https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation.html)  
40. Are there any deduplication scripts that use btrfs CoW as dedup?, 檢索日期：12月 17, 2025， [https://unix.stackexchange.com/questions/55193/are-there-any-deduplication-scripts-that-use-btrfs-cow-as-dedup](https://unix.stackexchange.com/questions/55193/are-there-any-deduplication-scripts-that-use-btrfs-cow-as-dedup)  
41. rui314/mold: mold: A Modern Linker \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rui314/mold](https://github.com/rui314/mold)  
42. Reclaiming disk space from cargo's target/ directories \- rtyler, 檢索日期：12月 17, 2025， [https://brokenco.de/2020/08/04/target-rich-environment.html](https://brokenco.de/2020/08/04/target-rich-environment.html)  
43. BD103/cargo-sweep: Remove stale build artifacts from your Cargo caches in Github Actions\!, 檢索日期：12月 17, 2025， [https://github.com/BD103/cargo-sweep](https://github.com/BD103/cargo-sweep)