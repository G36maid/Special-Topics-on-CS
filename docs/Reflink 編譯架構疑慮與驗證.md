# **Rust 建構系統之快取機制、指紋識別與工件重用策略的深度剖析報告**

## **執行摘要**

本報告旨在對 Rust Cargo 建構系統中的工件重用（Artifact Reuse）、建構快取（Build Caching）以及依賴指紋識別（Dependency Fingerprinting）機制進行詳盡的技術審計與分析。針對使用者提出的「是否有漏掉的部分」這一核心問題，本報告不僅檢視了官方文件中顯而易見的機制，更深入探討了檔案系統層級的互動、編譯器內部的雜湊演算法、以及在跨目錄、跨機器或容器化環境中實現持久化快取時可能遭遇的隱性邊緣情況。  
分析顯示，雖然 Cargo 提供了強大的本地增量編譯功能，但其設計初衷並非為了跨環境的工件重用。其對絕對路徑的依賴（存在於 dep-info 檔案、偵錯資訊及 panic 訊息中）、對檔案修改時間（mtime）的混合依賴模式，以及工作區路徑雜湊（Workspace Path Hashing）機制，構成了實現「一次編譯，到處執行」式快取的主要障礙。此外，常見的外部快取工具如 sccache 與 Rust 原生增量編譯之間的互斥性，以及使用 cp \--reflink 或 git clone 時 Metadata 的微妙變化，往往是導致快取失效的「盲點」。  
本報告將從底層原理出發，逐層剖析這些機制，並識別出在設計高階快取策略時容易被忽略的關鍵細節，最終提出基於檔案系統虛擬化（如 Bubblewrap）及精細化配置的解決方案。

## ---

**1\. Cargo 指紋識別與新鮮度檢查的核心機制**

要識別快取策略中的潛在漏洞，首先必須解構 Cargo 如何判斷一個編譯單元（Unit）是「新鮮（Fresh）」還是「髒（Dirty）」的。這不僅僅是簡單的內容雜湊，而是一個結合了檔案系統元數據與編譯器配置的混合模型。

### **1.1 混合式 Mtime/Hash 模型**

Cargo 的核心新鮮度檢查機制被稱為「指紋（Fingerprint）」。當一個編譯單元構建完成時，Cargo 會在 target/debug/.fingerprint/ 目錄下儲存指紋檔案。這個指紋並非單一維度，而是包含了兩個關鍵部分：

1. **元數據雜湊（Metadata Hash）：** 這是一個基於編譯器版本、編譯標誌（Flags）、環境變數、依賴項版本以及 Cargo.toml 配置計算出的雜湊值。這部分確保了如果編譯環境或依賴樹發生變化，構建將被視為過期。  
2. **檔案系統狀態（Filesystem State）：** 對於本地的源碼檔案，Cargo 並非每次都計算內容雜湊（因為這在大型專案中過於耗時）。相反，它記錄了構建結束時依賴檔案的修改時間（mtime）1。

關鍵盲點分析：  
許多開發者誤以為 Cargo 純粹依賴內容雜湊（Content Addressable）。然而，對於本地路徑依賴（Local Path Dependencies），Cargo 實際上執行的是 mtime 比較 1。具體邏輯是：Cargo 會讀取上一次構建生成的 dep-info 檔案（描述了哪些原始檔參與了編譯），然後比較這些原始檔當前的 mtime 與指紋檔案中記錄的時間戳。

* 如果 **任何一個原始檔的 mtime 新於指紋時間**，Cargo 就會判定該單元為「髒」，並觸發重新編譯 1。  
* 這意味著，即使檔案內容完全相同，僅僅是 touch 更新了時間戳，或者在 CI/CD 流程中 git clone 導致所有檔案時間被重置為當前時間，都會導致 Cargo 放棄現有快取並重新編譯。這是跨機器或跨時間點重用快取時最常見的失敗原因之一 2。

### **1.2 dep-info 檔案的角色與陷阱**

對於每一個編譯產出的工件（Artifact），rustc 會生成一個依賴資訊檔案（通常以 .d 結尾，類似 Makefile 語法）。這個檔案列出了生成該工件所需的所有輸入檔案路徑 4。

* **絕對路徑的預設行為：** 預設情況下，這些 .d 檔案包含的是 **絕對路徑** 4。例如，/home/user/project/src/lib.rs。  
* **重用阻礙：** 當 Cargo 進行新鮮度檢查時，它會解析這個檔案並檢查列出的路徑是否存在且未被修改。如果您將專案目錄從 /home/user/project\_v1 移動到 /home/user/project\_v2，Cargo 在讀取舊的 .d 檔案時，會發現 /home/user/project\_v1/src/lib.rs 不存在，從而判定依賴遺失，強制觸發重新編譯 6。

這是一個極易被忽視的細節：即使您使用了相對路徑引用依賴，Cargo 內部生成的依賴追蹤檔案仍然可能鎖死在絕對路徑上，除非進行顯式的配置干預。

### **1.3 build.rs 與隱性依賴**

建構腳本（build.rs）引入了另一層複雜性。Cargo 允許建構腳本透過標準輸出指令（如 cargo:rerun-if-changed=PATH）來動態告知 Cargo 哪些檔案應該被納入指紋計算 1。

* **預設的保守策略：** 如果建構腳本 **沒有** 輸出任何 rerun-if 指令，Cargo 會採取最保守的策略：只要套件目錄下的 **任何** 檔案發生變化（即使是無關的 README.md 或 .gitignore），它都會假設需要重新執行建構腳本 1。這會導致不必要的連鎖重新編譯。  
* **路徑解析：** rerun-if-changed 中的相對路徑是相對於套件根目錄解析的。但如果腳本邏輯中解析出了系統庫的絕對路徑並將其輸出，那麼該絕對路徑就成為了指紋的一部分，進一步降低了快取的路徑無關性 5。

## ---

**2\. 路徑敏感性與快取的可移植性問題**

在深入探討快取策略時，最核心的技術挑戰在於 **路徑敏感性（Path Sensitivity）**。Rust 編譯器和 Cargo 在多個層面上將原始碼的絕對路徑嵌入到二進制檔案和元數據中，這使得在不同目錄或機器間重用工件變得異常困難。這是許多「看似完美」的快取方案最終失敗的根本原因。

### **2.1 編譯器層面的路徑嵌入**

當 rustc 編譯程式碼時，它會將當前工作目錄和原始檔的絕對路徑嵌入到以下幾個位置：

1. **偵錯資訊（DWARF/PDB）：** 為了讓偵錯器（如 gdb, lldb）能夠在除錯時定位到原始碼，編譯器會在二進制檔案的 .debug\_line 和 .debug\_info 段中記錄絕對路徑 7。  
2. **Panic 訊息與 Backtrace：** std::panic\! 巨集和 std::backtrace 模組會捕捉檔案路徑以在程式崩潰時顯示。預設情況下，這些也是絕對路徑 7。  
3. **程序巨集（Proc-Macro）元數據：** 某些程序巨集可能會在展開過程中解析並嵌入檔案路徑，這取決於巨集的具體實作。

### **2.2 \--remap-path-prefix 的效力與侷限**

為了解決路徑嵌入問題，Rust 提供了 \--remap-path-prefix 編譯參數。例如，RUSTFLAGS="--remap-path-prefix=$(pwd)=/src" 可以將當前目錄映射為虛擬的 /src 路徑。這通常被視為實現「可重現建構（Reproducible Builds）」的標準解法 9。  
然而，這裡存在一個常被忽略的盲點：  
雖然 \--remap-path-prefix 可以清洗二進制檔案中的路徑（如 debug info 和 panic string），但它 並不一定 能修復 Cargo 自身維護的元數據 1。

* **連結器（Linker）的洩漏：** 即使 rustc 重映射了路徑，某些平台上的連結器（如 Windows MSVC 的 link.exe）仍可能將物件檔案（.o/.obj）的絕對路徑嵌入到最終的 PDB 或二進制檔案中，這是 rustc 無法完全控制的 9。  
* **指紋雜湊變動：** 使用 \--remap-path-prefix 本身會改變 RUSTFLAGS 的值。由於 RUSTFLAGS 是元數據雜湊的一部分，如果您在本地開發時不使用該 Flag，但在 CI 上使用，兩者生成的指紋將不匹配，導致無法共享快取 10。  
* **dep-info 的頑固性：** 歷史上，--remap-path-prefix 並不總能影響 Cargo 生成的 .d 檔案中的路徑。這意味著即使二進制檔案是路徑無關的，Cargo 的新鮮度檢查邏輯仍然鎖定在舊的絕對路徑上 11。

### **2.3 工作區路徑雜湊（Workspace Path Hashing）**

Cargo 在管理 target 目錄時，會根據 **工作區根目錄的絕對路徑** 計算一個雜湊值，並將其用於區分不同的依賴項建構。

* **現象：** 如果您將同一個專案複製到兩個不同的目錄（例如 /opt/proj\_a 和 /opt/proj\_b），即使它們共享同一個全域 CARGO\_TARGET\_DIR，Cargo 也會為它們建立不同的依賴項輸出目錄（例如 target/debug/deps 下會有不同雜湊後綴的檔案）12。  
* **影響：** 這直接導致了單純透過設定環境變數 CARGO\_TARGET\_DIR 來共享快取的策略在跨目錄場景下失效。Cargo 認為這兩個專案是完全獨立的實體，必須分別編譯。

## ---

**3\. 常見快取策略的結構性缺陷分析**

基於上述機制，我們可以深入分析使用者可能嘗試但容易遭遇挫折的幾種快取策略。這裡重點指出使用者概念中可能「漏掉」的結構性缺陷。

### **缺陷一：誤判 dep-info 的相對路徑配置**

使用者可能認為只要原始碼不變，將整個 target 目錄複製到新位置即可重用。

* 漏掉的細節： 必須顯式配置 build.dep-info-basedir。  
  如果不設置此選項，.d 檔案中的絕對路徑會導致 Cargo 在新位置找不到依賴項而觸發重建 4。這是一個必須在 .cargo/config.toml 中手動開啟的設定，而非預設行為。  
  Ini, TOML  
  \[build\]  
  dep-info-basedir \= "."

  唯有如此，.d 檔案才會記錄 src/lib.rs 而非 /abs/path/to/src/lib.rs，從而允許目錄移動後的重用 14。

### **缺陷二：sccache 與增量編譯的互斥性**

使用者可能引入 sccache（Shared Compilation Cache）作為跨機器快取的銀彈，期望它能加速所有場景。

* **漏掉的細節：** sccache 與 Rust 的 **增量編譯（Incremental Compilation）** 在根本上是不兼容的 15。  
  * **原理衝突：** 增量編譯將程式碼拆分為多個代碼生成單元（CGU），並依賴於極其細粒度的中間狀態。sccache 則是在編譯器調用層級運作，快取的是完整編譯產物。  
  * **實際後果：** 在 Cargo 的預設配置下（profile.dev 啟用增量編譯），sccache 通常無法快取編譯結果，或者必須強制關閉增量編譯才能生效。  
  * **權衡：** 這意味著在本地開發循環（Edit-Compile-Run）中，使用 sccache 可能反而比原生的 Cargo 增量編譯 **更慢**，因為您犧牲了細粒度的增量更新，換取了粗粒度的快取命中 15。sccache 更適合 CI 環境或 release 建構，而非本地除錯。

### **缺陷三：檔案系統虛擬化的必要性**

使用者可能嘗試透過符號連結（Symlink）或 bind mount 來欺騙 Cargo，使其認為路徑一致。

* **漏掉的細節：** Cargo 和 rustc 會解析符號連結到其規範路徑（Canonical Path）18。  
  * 如果您將 /shared/cache 軟連結到 /project/target，Cargo 在計算雜湊或檢查路徑時，可能會解析出 /shared/cache 這個真實路徑。如果之前的建構是基於 /project/target 進行的，路徑不匹配將導致指紋校驗失敗（SVH mismatch）。  
  * **唯一解法：** 使用 **Mount Namespace**（如 Docker 或 Bubblewrap）是唯一能徹底解決路徑敏感性的方案。透過將專案掛載到容器內的固定路徑（如 /workspace），無論宿主機路徑為何，Cargo 看到的永遠是 /workspace，從而實現完美的指紋匹配 19。

### **缺陷四：全域鎖定與並發衝突**

使用者可能試圖讓所有專案共享同一個全域 target 目錄以節省磁碟空間。

* **漏掉的細節：** Cargo 的鎖定粒度與特徵（Feature）統一問題。  
  * **鎖定：** Cargo 在操作全域快取或共享目錄時會使用檔案鎖。多個並發的 Cargo 進程（例如 IDE 的 cargo check 和終端的 cargo run）如果共享同一個目錄，可能會頻繁遭遇 Blocking waiting for file lock，嚴重影響開發體驗 21。  
  * **特徵污染：** 如果專案 A 和專案 B 依賴同一個庫但啟用了不同的 Features，共享 Target 目錄可能導致頻繁的重新編譯，因為 Cargo 發現已快取的構建產物與當前請求的 Feature Set 不匹配（儘管 Cargo 會嘗試用雜湊區分，但在複雜依賴樹下仍有邊緣情況）23。

## ---

**4\. 進階快取架構與實施方案深度剖析**

基於上述分析，我們可以構建出幾種不同層級的快取架構。本節將對比這些方案的優劣，幫助使用者識別其概念中可能缺失的高階實作細節。

### **4.1 方案 A：基於 Docker/Bubblewrap 的容器化建構**

這是目前最穩健的跨環境快取策略，解決了所有路徑敏感性問題。

* **核心機制：** 使用 Linux Namespace 技術（unshare, bwrap）建立一個隔離的掛載命名空間。  
* 實作細節：  
  無論宿主機上的原始碼位於何處（/home/alice/src, /home/bob/src），都將其 Bind Mount 到容器內的固定路徑（例如 /source）。同時將 Cargo Registry 和 Target 目錄也掛載到固定位置。  
  Bash  
  \# 示意圖：使用 bwrap 規範化路徑  
  bwrap \--bind /host/project /source \\  
        \--bind /host/registry /usr/local/cargo \\  
        \--cwd /source \\  
        cargo build

* **優勢：** 徹底消除了絕對路徑導致的指紋差異。dep-info、Debug Info 和 Panic 訊息中的路徑在所有機器上都是一致的 /source/...。  
* **使用者可能漏掉的點：** 這需要特權（或 User Namespaces 支援）。在某些受限的 CI 環境（如非特權 Pod）中，嵌套容器或 unshare 可能被禁止 24。

### **4.2 方案 B：基於 Reflink 的寫入時複製（CoW）快取**

針對現代檔案系統（Btrfs, XFS, APFS）的優化策略。

* **核心機制：** 利用 cp \--reflink=always 快速複製 Target 目錄 26。這允許每個專案擁有獨立的 target 目錄（避免鎖定衝突），但底層數據塊共享（節省空間）。  
* **風險與盲點：** **Mtime 的時序問題**。  
  * 當執行 cp \-r 時，新複製的檔案預設會獲得「當前時間」作為 mtime（除非使用 \-p）。  
  * 如果您的原始碼是剛從 Git 檢出的，其 mtime 也是「當前時間」。  
  * **競態條件：** 如果原始碼的 mtime 微秒級地晚於 Artifact 的 mtime，Cargo 會認為原始碼更新，從而觸發重新編譯 27。  
  * **解決方案：** 必須配合 git-restore-mtime 工具，將原始碼的 mtime 重置為 Commit 時間（即過去的時間），確保 Artifact Mtime \> Source Mtime 28。這是許多 Reflink 策略失敗的關鍵原因。

### **4.3 方案 C：sccache 的正確部署**

* **核心機制：** 包裝 rustc 調用，將輸入雜湊後查詢遠端快取。  
* **關鍵配置：**  
  * 必須顯式設定 RUSTC\_WRAPPER=sccache。  
  * **必須在 CI/Release 建構中顯式關閉增量編譯** (CARGO\_INCREMENTAL=0)，否則 sccache 的命中率極低 15。  
  * 對於路徑無關性，sccache 自身提供了一些重映射功能，但最可靠的方式仍是結合方案 A（容器化）來保證輸入路徑的一致性 30。

## ---

**5\. 比較分析與數據展示**

為了更清晰地展示不同因素對快取重用的影響，以下表格總結了關鍵機制及其對應的失敗模式。

### **表 1：Cargo 新鮮度檢查失敗模式分析**

| 機制組件 | 檢查內容 | 常見失敗場景（導致意外重建） | 解決方案/緩解措施 |
| :---- | :---- | :---- | :---- |
| **Dep-info** | 依賴檔案列表 | 移動專案目錄後，絕對路徑失效 | 設定 build.dep-info-basedir \= "." |
| **Mtime** | 檔案修改時間 | git clone 或 cp 重置了 mtime，導致其新於快取工件 | 使用 git-restore-mtime 或 cp \-p |
| **Metadata** | 編譯標誌雜湊 | 本地與 CI 使用不同的 RUSTFLAGS (如 \--remap-path-prefix) | 統一 config.toml 中的編譯標誌 |
| **Path Hash** | 工作區根目錄 | 將專案複製到新路徑，Cargo 視為不同工作區 | 使用容器固定路徑或 CARGO\_TARGET\_DIR (有副作用) |
| **Symlinks** | 檔案路徑解析 | 使用軟連結共享 Target，但 Cargo 解析出真實路徑導致 SVH 不匹配 | 使用 Bind Mounts 或容器化 |

### **表 2：sccache 與 Cargo 原生快取對比**

| 特性 | Cargo 原生增量編譯 | sccache (共享快取) | 整合建議 |
| :---- | :---- | :---- | :---- |
| **顆粒度** | 函數/CGU 級別 (極細) | Crate/Invocation 級別 (粗) | 本地開發用 Cargo，CI 用 sccache |
| **狀態依賴** | 高 (依賴上一次的由來) | 無 (Stateless) | 互斥：sccache 需關閉增量編譯 |
| **路徑敏感** | 極高 (嵌入絕對路徑) | 高 (需路徑一致或重映射) | 配合 Docker/Bubblewrap 使用 |
| **連結速度** | 無加速 (仍需連結) | 無加速 | 使用 lld 或 mold 連結器優化 |

## ---

**6\. 特殊工具與生態系統深度整合**

除了上述核心機制，還有一些工具和參數在特定場景下至關重要，這些往往是構建高效流水線時容易遺漏的組件。

### **6.1 git-restore-mtime 的必要性**

在 CI/CD 流水線中，快取策略通常涉及「恢復 target 目錄」和「檢出程式碼」。

* **問題：** Git 不保存 mtime。每次 Pipeline 執行 git checkout，所有源碼 mtime 變為 now()。如果 target 快取是從上次構建恢復的（mtime 為 past），Cargo 會看到 Source(now) \> Artifact(past)，判斷所有檔案都已變更，導致全量重建。  
* **整合：** 在恢復 Cache 之後、執行 Build 之前，必須執行 git-restore-mtime。這會讀取 Git 歷史，將檔案 mtime 修改為最後一次 Commit 的時間。這樣 Cargo 就會看到 Source(commit\_time) \< Artifact(build\_time)，從而正確使用快取 28。

### **6.2 連結器（Linker）的影響**

rustc 的編譯時間只是一部分，連結時間在大型 Rust 專案中佔比巨大。

* **漏掉的部分：** sccache **不快取連結步驟**。  
* **優化：** 在 Linux 上使用 mold 或 lld 連結器可以顯著減少連結時間。這與 Cargo 的快取策略是正交的，但在總體構建時間優化中不可或缺 32。

### **6.3 未來展望：RFC 3127 (trim-paths)**

Rust 社群正在推動 RFC 3127，旨在標準化路徑修剪功能。

* **現狀：** 目前 \--remap-path-prefix 是權宜之計。  
* **未來：** \-Z trim-paths (Nightly) 試圖在編譯器級別更智慧地處理路徑，包括區分「巨集展開範圍」和「診斷訊息範圍」，從而解決 dep-info 和 Panic 訊息的路徑洩漏問題。密切關注此 RFC 的穩定化進程對於長期維護快取策略至關重要 1。

## ---

**7\. 結論與建議**

綜合上述分析，您的概念中可能「漏掉」或未充分重視的部分主要集中在 **檔案系統元數據的微妙互動** 以及 **路徑一致性的嚴格要求**。

### **關鍵遺漏總結：**

1. **dep-info 的絕對路徑陷阱：** 僅僅複製 target 目錄是不夠的，必須配置 dep-info-basedir 才能使依賴追蹤相對化。  
2. **Mtime 的時序破壞：** 忽略了 git clone 對 mtime 的重置作用，導致快取在 CI 環境中失效。必須引入 mtime 恢復步驟。  
3. **增量編譯與共享快取的衝突：** 未意識到 sccache 會犧牲本地開發的增量編譯優勢，需根據場景動態切換配置。  
4. **工作區身分識別：** 低估了 Cargo 基於路徑雜湊區分工作區的嚴格程度，單純的路徑重映射往往不足以欺騙 Cargo，**容器化/Namespace 隔離** 才是最徹底的解法。

### **行動建議：**

為了構建一個無懈可擊的 Rust 建構快取系統，建議採取以下層次化策略：

1. **基礎層（配置）：** 在所有專案中設定 .cargo/config.toml，啟用 build.dep-info-basedir \= "."。  
2. **環境層（隔離）：** 使用 Docker 或 Bubblewrap 將建構環境的路徑標準化（例如統一為 /workspace），這是解決路徑敏感性的終極方案。  
3. **操作層（時序）：** 在 CI 流程中整合 git-restore-mtime，確保源碼時間戳記早於快取工件。  
4. **工具層（加速）：** 針對 CI 使用 sccache（並關閉增量編譯），針對本地開發使用原生 Cargo 增量編譯，並考慮使用 mold 連結器。

透過補足這些細節，您可以將一個「理論上可行」的快取策略轉化為一個在生產環境中「穩定高效」的構建系統。

#### **引用的著作**

1. Module fingerprint \- cargo::core::compiler \- Rust Documentation, 檢索日期：12月 17, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html)  
2. Branch checkout updates timestamps on some files\! : r/git \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/git/comments/253fsr/branch\_checkout\_updates\_timestamps\_on\_some\_files/](https://www.reddit.com/r/git/comments/253fsr/branch_checkout_updates_timestamps_on_some_files/)  
3. cargo build does not rebuild if a source file was modified during a build · Issue \#2426 · rust-lang/cargo \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/2426](https://github.com/rust-lang/cargo/issues/2426)  
4. Build Cache \- The Cargo Book \- Rust Documentation, 檢索日期：12月 17, 2025， [https://doc.rust-lang.org/cargo/reference/build-cache.html](https://doc.rust-lang.org/cargo/reference/build-cache.html)  
5. Relative paths in \`cargo:rerun-if-changed\` are not properly resolved in depfiles, 檢索日期：12月 17, 2025， [https://internals.rust-lang.org/t/relative-paths-in-cargo-rerun-if-changed-are-not-properly-resolved-in-depfiles/14563](https://internals.rust-lang.org/t/relative-paths-in-cargo-rerun-if-changed-are-not-properly-resolved-in-depfiles/14563)  
6. Moving CARGO\_HOME invalidates target caches · Issue \#10915 · rust-lang/cargo \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/10915](https://github.com/rust-lang/cargo/issues/10915)  
7. 3127-trim-paths \- The Rust RFC Book, 檢索日期：12月 17, 2025， [https://rust-lang.github.io/rfcs/3127-trim-paths.html](https://rust-lang.github.io/rfcs/3127-trim-paths.html)  
8. Only with \`all\` or \`split-debuginfo\` can \`-Zremap-path-scope\` remap \`SO\` symbols on macOS · Issue \#117652 · rust-lang/rust \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/rust/issues/117652](https://github.com/rust-lang/rust/issues/117652)  
9. Remap source paths \- The rustc book \- Rust Documentation, 檢索日期：12月 17, 2025， [https://doc.rust-lang.org/beta/rustc/remap-source-paths.html](https://doc.rust-lang.org/beta/rustc/remap-source-paths.html)  
10. Reconsider RUSTFLAGS artifact caching. · Issue \#8716 · rust-lang/cargo \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/8716](https://github.com/rust-lang/cargo/issues/8716)  
11. Cargo should print appropriate relative paths when being run from a non-root folder \#9887, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/9887](https://github.com/rust-lang/cargo/issues/9887)  
12. Rework Cargo Build Dir Layout \- Rust Project Goals \- GitHub Pages, 檢索日期：12月 17, 2025， [https://rust-lang.github.io/rust-project-goals/2025h2/cargo-build-dir-layout.html](https://rust-lang.github.io/rust-project-goals/2025h2/cargo-build-dir-layout.html)  
13. When sharing CARGO\_TARGET\_DIR , cargo does not distinguish between 2 path deps with the same name/version \#12516 \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/12516](https://github.com/rust-lang/cargo/issues/12516)  
14. Build Cache \- The Cargo Book \- · DOKK, 檢索日期：12月 17, 2025， [https://dokk.org/documentation/rust-cargo/0.49.0/guide/build-cache.html](https://dokk.org/documentation/rust-cargo/0.49.0/guide/build-cache.html)  
15. Does sccache really help? : r/rust \- Reddit, 檢索日期：12月 17, 2025， [https://www.reddit.com/r/rust/comments/rvqxkf/does\_sccache\_really\_help/](https://www.reddit.com/r/rust/comments/rvqxkf/does_sccache_really_help/)  
16. Rust and incremental compilation · Issue \#236 · mozilla/sccache \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/mozilla/sccache/issues/236](https://github.com/mozilla/sccache/issues/236)  
17. Benchmarking rust compilation speedups and slowdowns from sccache and \-Zthreads, 檢索日期：12月 17, 2025， [https://neosmart.net/blog/benchmarking-rust-compilation-speedups-and-slowdowns-from-sccache-and-zthreads/](https://neosmart.net/blog/benchmarking-rust-compilation-speedups-and-slowdowns-from-sccache-and-zthreads/)  
18. Not reproducible when a project is copied to another directory · Issue \#13586 · rust-lang/cargo \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/13586](https://github.com/rust-lang/cargo/issues/13586)  
19. Bubblewrap \- ArchWiki, 檢索日期：12月 17, 2025， [https://wiki.archlinux.org/title/Bubblewrap](https://wiki.archlinux.org/title/Bubblewrap)  
20. Malicious versions of Nx and some supporting plugins were published \- Hacker News, 檢索日期：12月 17, 2025， [https://news.ycombinator.com/item?id=45034496](https://news.ycombinator.com/item?id=45034496)  
21. Target directory isolation/locking fails when cross-compiling · Issue \#5968 · rust-lang/cargo, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/5968](https://github.com/rust-lang/cargo/issues/5968)  
22. Blocking waiting for file lock on package cache · Issue \#11566 · rust-lang/cargo \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rust-lang/cargo/issues/11566](https://github.com/rust-lang/cargo/issues/11566)  
23. Fingerprint of dependency in workspace changes when running \`cargo build\` and \`cargo build \-p  
24. Can't run any flatpak app \- Ask Ubuntu, 檢索日期：12月 17, 2025， [https://askubuntu.com/questions/1489166/can-t-run-any-flatpak-app](https://askubuntu.com/questions/1489166/can-t-run-any-flatpak-app)  
25. Isolate (sandbox) language servers · Issue \#12358 · zed-industries/zed \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/zed-industries/zed/issues/12358](https://github.com/zed-industries/zed/issues/12358)  
26. Replace hardlinks with cp \--reflink · Issue \#65 · rsnapshot/sourceforge-issues \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/rsnapshot/sourceforge-issues/issues/65](https://github.com/rsnapshot/sourceforge-issues/issues/65)  
27. Why doesn't Git set the file time? \- Software Engineering Stack Exchange, 檢索日期：12月 17, 2025， [https://softwareengineering.stackexchange.com/questions/350403/why-doesnt-git-set-the-file-time](https://softwareengineering.stackexchange.com/questions/350403/why-doesnt-git-set-the-file-time)  
28. Restore a file's modification time in Git \- Stack Overflow, 檢索日期：12月 17, 2025， [https://stackoverflow.com/questions/2458042/restore-a-files-modification-time-in-git](https://stackoverflow.com/questions/2458042/restore-a-files-modification-time-in-git)  
29. What's the equivalent of Subversion's "use-commit-times" for Git? \- Stack Overflow, 檢索日期：12月 17, 2025， [https://stackoverflow.com/questions/1964470/whats-the-equivalent-of-subversions-use-commit-times-for-git](https://stackoverflow.com/questions/1964470/whats-the-equivalent-of-subversions-use-commit-times-for-git)  
30. mozilla/sccache: Sccache is a ccache-like tool. It is used as a compiler wrapper and avoids compilation when possible. Sccache has the capability to utilize caching in remote storage environments, including various cloud storage options, or alternatively, in local storage. \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/mozilla/sccache](https://github.com/mozilla/sccache)  
31. Cache misses when different projects shares same dependencies · Issue \#196 · mozilla/sccache \- GitHub, 檢索日期：12月 17, 2025， [https://github.com/mozilla/sccache/issues/196](https://github.com/mozilla/sccache/issues/196)  
32. Accelerating Rust Web App Builds \- Leapcell, 檢索日期：12月 17, 2025， [https://leapcell.io/blog/accelerating-rust-web-app-builds](https://leapcell.io/blog/accelerating-rust-web-app-builds)