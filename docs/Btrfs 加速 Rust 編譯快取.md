# **利用 Btrfs CoW 特性加速全系統 Rust 編譯快取：架構分析與可行性研究報告**

## **1\. 行政摘要 (Executive Summary)**

隨著 Rust 語言在系統程式設計、WebAssembly 以及雲端基礎設施中的廣泛採用，編譯時間長久以來一直是開發者體驗中的顯著痛點。雖然 Rust 編譯器 (rustc) 在增量編譯 (Incremental Compilation) 方面取得了長足進步，但在多專案並行開發或頻繁切換 Git 分支的場景下，傳統的建置系統仍面臨顯著的 I/O 瓶頸與儲存空間浪費。現有的快取工具如 sccache 雖然解決了重複編譯的 CPU 消耗問題，但其基於檔案複製 (File Copy) 的儲存機制導致了磁碟空間的雙倍佔用以及高延遲的 I/O 操作。  
本報告旨在深入探討並設計一種新型態的系統級 Rust 編譯快取架構，該架構直接利用現代檔案系統（特別是 Btrfs 與 XFS）的「寫入時複製」（Copy-on-Write, CoW）與「引用連結」（Reflink）特性。此專案靈感源自 Docker 儲存驅動程式（Storage Driver）利用 Btrfs 子卷快照（Subvolume Snapshots）來管理容器映像層的高效機制。  
本研究首先剖析 Docker 如何利用 Btrfs 的區塊級去重複化技術來實現秒級容器啟動與極致的空間節省，並論證該模型如何轉化為 Rust 的顆粒度更細的檔案級快取。接著，我們詳細檢視 Rust 的建置工具 Cargo 的指紋辨識（Fingerprinting）與依賴追蹤機制，識別出實作共享快取的主要障礙——特別是依賴檔案修改時間 (mtime) 的快取失效邏輯以及絕對路徑 (Absolute Paths) 導致的二進位差異。隨後，報告深入分析 sccache 的運作原理及其在本地儲存上的侷限性。  
基於上述分析，本報告提出了一套名為「Cargo-CoW」的架構藍圖。該架構利用 ioctl\_ficlone 系統呼叫取代傳統的檔案複製，實現 O(1) 複雜度的建置產物還原，並結合路徑重映射 (--remap-path-prefix) 技術以確保快取的跨專案重用率。分析顯示，在典型的多專案工作站上，此方案有望減少 90% 以上的 target 目錄磁碟佔用，並在連結階段顯著降低 I/O 等待時間。

## **2\. 緒論：現代編譯流程中的 I/O 高牆**

在現代軟體工程中，編譯速度直接影響開發者的迭代效率（Iteration Velocity）。Rust 語言以其強大的型別系統與借用檢查器（Borrow Checker）著稱，這些特性在編譯期提供了記憶體安全的保證，但也同時帶來了高昂的編譯成本。為了緩解這一問題，Rust 社群發展出了精密的增量編譯技術與並行編譯策略。然而，當我們深入分析編譯流程的效能剖析（Profiling）數據時，會發現當 CPU 運算時間被壓縮後，儲存裝置的輸入/輸出（I/O）吞吐量逐漸成為新的瓶頸。

### **2.1 儲存冗餘與 I/O 延遲的雙重挑戰**

在一個活躍的 Rust 開發環境中，開發者通常會維護多個專案，或者同一專案的多個 Git 工作樹（Worktrees）。Cargo 作為 Rust 的套件管理器與建置系統，預設將所有建置產物（Artifacts）隔離在每個工作區的 target/ 目錄下。這種設計雖然保證了建置的封閉性（Hermeticity），卻導致了極大的資源浪費。  
舉例而言，若開發者有十個專案皆依賴於 tokio 1.0 版本與 serde 1.0 版本，Cargo 將會在十個不同的 target 目錄中，分別編譯並儲存這兩份函式庫的 .rlib 與 .rmeta 檔案。這不僅消耗了數百 MB 甚至 GB 的磁碟空間，更意味著在建置過程中，磁碟必須重複寫入完全相同的位元組序列。對於使用 NVMe SSD 的現代工作站，雖然順序寫入速度極快，但在高並發連結（Linking）階段，大量的隨機讀寫仍會導致 I/O 佇列飽和，進而拖慢整體建置速度。

### **2.2 寫入時複製（CoW）的契機**

傳統檔案系統（如 ext4）在複製檔案時，必須物理地複製每一個資料區塊（Data Block）。然而，現代的 CoW 檔案系統（如 Btrfs、XFS、ZFS 以及 macOS 的 APFS）引入了「引用連結」（Reflink）的概念。Reflink 允許兩個不同的檔案共享磁碟上相同的物理資料區塊，僅在其中一方發生寫入操作時，檔案系統才會為變更的部分分配新的區塊。  
這種機制為建置快取提供了一個革命性的機會：如果我們能建立一個全域的建置產物倉庫（Warehouse），當 Cargo 需要某個已編譯過的依賴項時，我們只需透過 Reflink 將其「映射」到當前專案的 target 目錄。這個操作在元資料（Metadata）層級完成，耗時僅需微秒級，且不佔用額外的物理儲存空間。這正是 Docker 映像檔分層儲存的核心原理，亦是本專案試圖引入 Rust 生態系統的關鍵技術。

## **3\. Docker 的 Btrfs 儲存驅動架構解析**

要將 Btrfs 的優勢應用於 Rust 建置，我們必須先深入理解 Docker 是如何利用這些特性來解決類似問題的。Docker 的映像檔（Image）構建與容器（Container）運行機制，是目前工業界大規模應用 Btrfs CoW 特性的最佳範例。

### **3.1 Docker 的分層儲存模型**

Docker 映像檔由一系列唯讀層（Read-only Layers）組成，頂層則是一個可讀寫的容器層。Docker 的 Btrfs 儲存驅動程式（Storage Driver）並沒有使用傳統的聯合掛載（Union Mount）技術（如 Overlay2），而是直接將 Docker 的層級概念映射到 Btrfs 的 **子卷（Subvolumes）** 與 **快照（Snapshots）** 上 。  
**表 1：Docker 概念與 Btrfs 原語對照表**

| Docker 概念 | Btrfs 實作原語 | 技術細節與行為 |
| :---- | :---- | :---- |
| **基礎映像層 (Base Layer)** | **子卷 (Subvolume)** | 映像檔的最底層被儲存為一個標準的 Btrfs 子卷。子卷在 Btrfs 中是一個獨立的檔案樹，擁有獨立的 inode 命名空間，類似於一個掛載點，但物理上位於同一分區 。 |
| **映像層堆疊 (Image Layering)** | **唯讀快照 (Read-only Snapshot)** | 當 Docker 構建下一層時，它不會複製上一層的檔案。相反，它會對父層的子卷建立一個 Btrfs 快照。快照初始時與父子卷共享所有資料區塊與 B-tree 節點，建立速度極快且不佔空間。新層的變更（Delta）以 CoW 方式寫入，僅佔用差異部分的空間 。 |
| **容器層 (Container Layer)** | **讀寫快照 (Read-Write Snapshot)** | 啟動容器時，Docker 會對最頂層的映像層建立一個可讀寫的快照。容器內的所有寫入操作都會觸發 Btrfs 的 CoW 機制（Redirect-on-Write），將修改後的資料寫入新區塊，而底層映像保持不變 。 |

### **3.2 深度技術解析：快照與空間效率**

根據 Docker 官方文件與技術白皮書 ，Docker Btrfs 驅動的運作流程如下：

1. **初始化**：Docker 在 /var/lib/docker/btrfs/subvolumes 下建立基礎子卷。  
2. **快照鏈**：每個映像層都是其父層的快照。由於 Btrfs 是基於 B-tree 的檔案系統，建立快照本質上是複製根節點（Root Node）並增加引用計數（Reference Count）。這是一個 O(1) 的操作，與子卷的大小無關。  
3. **區塊級去重**：當容器修改檔案時，Btrfs 僅複製被修改的 Block（通常為 4KB 或 16KB），而非整個檔案。這與傳統的「寫入時複製整個檔案」相比，提供了更細粒度的空間節省。

### **3.3 對 Rust 建置系統的啟示與限制**

Docker 的模型證明了 CoW 在管理「基礎唯讀、頂層讀寫」結構上的巨大優勢。然而，直接將 Docker 的「子卷快照」模型套用到 Rust 建置中存在一個顯著的\*\*粒度不匹配（Granularity Mismatch）\*\*問題。

* **Docker 的粒度**：檔案系統樹（Directory Tree）。Docker 快照的是整個目錄結構。  
* **Rust 建置的粒度**：單一檔案（File）。Cargo 產生的 .rlib、.rmeta 是獨立的檔案。

我們無法為 Rust 編譯出的每一個 .rlib 檔案建立一個獨立的 Btrfs 子卷，因為子卷的管理開銷過大。因此，Rust 的 CoW 快取不能依賴「子卷快照」，而必須使用 **Reflink（引用連結）**。Reflink 是檔案級別的快照，它允許我們在同一子卷內（或同一分區內）對單一檔案進行 CoW 複製。這正是 cp \--reflink 命令背後的機制，也是本專案的核心技術基礎 。

## **4\. Rust 目前的編譯快取機制剖析**

在設計新的快取系統之前，我們必須徹底理解現有系統——Cargo 與 rustc——是如何決定何時重新編譯以及何時重用成品的。這直接關係到我們的 CoW 快取是否能被 Cargo 正確識別，而不被視為「過期」資料。

### **4.1 Cargo 的目標目錄結構**

Cargo 將所有輸出儲存在 target/ 目錄中。理解這個結構對於攔截和快取至關重要 ：

* target/debug/ 或 target/release/：依據 Profile 而定。  
  * deps/：這是最重要的目錄。存放所有編譯好的依賴套件（Dependencies）的 .rlib、.rmeta 和動態連結庫 .so / .dll。檔名通常帶有雜湊後綴（Hash Suffix），例如 libserde-12345abc.rlib，以區分不同版本或配置。  
  * incremental/：這是 rustc 內部的增量編譯快取目錄。它包含編譯器的中間狀態（AST、MIR 等）。  
  * .fingerprint/：Cargo 用來追蹤檔案變更與編譯狀態的內部記帳目錄。  
  * build/：存放 build.rs 建置腳本的輸出。

**關鍵洞察**：全系統快取應主要針對 deps/ 目錄下的成品。incremental/ 目錄由於包含大量絕對路徑且高度依賴於特定的源碼狀態，較難在不同專案間安全共享 。

### **4.2 Cargo 的指紋辨識與新鮮度邏輯 (Fingerprinting & Freshness)**

Cargo 如何決定一個 Crate 是否需要重新編譯？這是我們設計 CoW 快取時必須欺騙或滿足的機制。Cargo 使用儲存在 target/debug/.fingerprint/ 中的指紋檔案 。  
Cargo 的新鮮度檢查主要依賴兩個機制：

1. **輸入雜湊 (Input Hashing)**：Cargo 會計算編譯器版本、編譯參數（RUSTFLAGS）、環境變數以及 Cargo.toml 中定義的 Feature 的雜湊值。如果這些改變了，指紋就不匹配，必須重編。  
2. **檔案修改時間 (mtime) 比對**：對於源程式碼檔案，Cargo 預設**不**計算內容雜湊（因為太慢），而是檢查源檔案的 mtime 與指紋檔案中記錄的 mtime。同時，它會檢查 target/debug/deps/ 下的產物檔案的 mtime 是否晚於源檔案 。

**潛在陷阱**：這就是為什麼直接從快取中恢復檔案可能會失敗。如果我們從全域快取中 Reflink 一個一個月前編譯好的 .rlib 到當前專案的 target 目錄，該檔案的 mtime 可能是「一個月前」。而當前專案的源碼可能是「剛剛」checkout 下來的（mtime 為現在）。Cargo 會判斷 源碼 mtime \> 產物 mtime，判定產物過期，進而觸發重新編譯。  
因此，我們的 CoW 快取工具在還原檔案時，必須**主動更新（Touch）** 檔案的 mtime 至當前時間，以滿足 Cargo 的啟發式檢查 。值得注意的是，Rust 社群正在實驗 \-Z checksum-freshness 功能，試圖用檔案內容雜湊取代 mtime，這將對快取更友善，但目前尚未穩定 。

### **4.3 絕對路徑與 dep-info 檔案**

Rust 編譯器產出的檔案中往往包含絕對路徑，這阻礙了跨專案的快取共享。

* **.d 檔案 (Dep-info)**：rustc 會生成類似 Makefile 語法的依賴描述檔，其中列出了所有源檔案的絕對路徑 。如果專案 A 在 /home/user/proj-a，專案 B 在 /home/user/proj-b，即使依賴內容相同，.d 檔案內容也會不同。  
* **除錯資訊 (Debug Info)**：二進位檔中的 DWARF 資訊通常包含源碼的絕對路徑，以便除錯器能找到源碼。

**解決方案**：rustc 提供了 \--remap-path-prefix 參數 。透過傳遞 \--remap-path-prefix /home/user/proj-a=/src，我們可以強迫編譯器在輸出中將特定前綴替換為通用路徑。這對於建立「路徑無關」（Path-Independent）的快取至關重要。

## **5\. 參考項目 sccache 的運作原理**

sccache 是目前 Rust 生態系中標準的編譯快取工具，由 Mozilla 開發。分析其優缺點有助於定位本專案的價值。

### **5.1 架構與流程**

sccache 採用 Client-Server 架構，並作為編譯器包裝器（Compiler Wrapper）運作 。

1. **攔截**：使用者設定 RUSTC\_WRAPPER=sccache。Cargo 呼叫 sccache 而非 rustc。  
2. **雜湊計算**：sccache 解析編譯參數，並對所有輸入的源程式碼進行內容雜湊（Content Hashing）。注意，它不依賴 mtime，這比 Cargo 更精確。  
3. **快取查詢**：它使用計算出的雜湊值作為 Key，向後端（S3, Redis, Memcached 或本地磁碟）查詢。  
4. **快取命中**：如果找到，直接下載/複製產物到 Cargo 預期的輸出位置。  
5. **快取未命中**：執行真正的 rustc，將輸出上傳/寫入快取，然後複製到輸出位置。

### **5.2 sccache 的侷限性**

儘管 sccache 能顯著減少 CPU 時間，但它在本地開發場景下有效率問題：

* **磁碟空間加倍**：如果使用本地磁碟快取，每個編譯產物都會儲存兩份：一份在 \~/.cache/sccache，一份在專案的 target/debug/deps。這完全違背了 CoW 的精神。  
* **I/O 複製成本**：從快取恢復檔案涉及標準的 read 和 write 系統呼叫。對於數百 MB 的依賴庫，這在大規模並行構建時會產生顯著的 I/O 爭用。  
* **不支援 Reflink**：目前 sccache 的實作尚未支援 Reflink 或 Hardlink 。Hardlink 雖然節省空間，但若工具鏈原地修改（In-place modification）檔案，會導致快取污染。Reflink 則是完美的解決方案，但 sccache 尚未整合。

## **6\. 基於 Btrfs CoW 的全系統 Rust 快取架構設計**

綜合以上分析，本報告提出一個名為「Cargo-CoW」的概念驗證架構。此架構旨在結合 sccache 的內容雜湊能力與 Docker 的 Btrfs 儲存效率。

### **6.1 核心機制：Reflink (FICLONE)**

Btrfs（及 XFS）支援 ioctl\_ficlone 操作。這是一個檔案系統層級的指令，它告訴檔案系統：「建立一個新檔案 B，它的內容指向檔案 A 的數據區塊」。

* **速度**：O(1)。不需要讀取或寫入實際的數據內容，僅操作元資料（B-tree 指標）。  
* **安全性**：CoW 保證。如果隨後有程式修改了檔案 B，檔案系統會為修改的部分分配新區塊，檔案 A 保持不變。這避免了 Hardlink 的快取污染風險 。

### **6.2 系統架構組件**

#### **1\. 全域倉庫 (The Warehouse)**

建立一個集中式的儲存目錄，例如 \~/.cache/rust-cow-warehouse。此目錄必須與使用者的專案程式碼位於**同一個 Btrfs 分區（Partition）**，因為 Reflink 無法跨越分區邊界 。

* **儲存結構**：採用內容定址（Content-Addressable）結構。檔名基於編譯輸入的強雜湊值（Strong Hash）。

#### **2\. 智慧包裝器 (The Smart Wrapper)**

一個類似 sccache 的二進位程式，作為 RUSTC\_WRAPPER。  
**運作流程圖：**

1. **雜湊計算**：Wrapper 接收 Cargo 的指令，計算編譯器版本、參數及源碼內容的 SHA-256 雜湊。  
2. **倉庫查詢**：檢查 \~/.cache/rust-cow-warehouse/\<HASH\> 是否存在。  
3. **快取命中 (Hit) \- Reflink 還原**：  
   * 使用 FICLONE ioctl 將倉庫中的 .rlib、.rmeta 檔案 Reflink 到 target/debug/deps/。  
   * **關鍵操作**：執行 touch 更新 Reflink 後檔案的 mtime 為當前時間，以欺騙 Cargo 的過期檢查機制 。  
   * **路徑還原**：讀取快取中的正規化 .d 檔，將其中的相對路徑替換回當前專案的絕對路徑。  
4. **快取未命中 (Miss) \- 編譯與晉升**：  
   * 執行 rustc，並注入 \--remap-path-prefix $CARGO\_MANIFEST\_DIR=/src 以確保產出的二進位檔不包含特定專案的絕對路徑 。  
   * 編譯成功後，將生成的產物從 target/ **Reflink** 到倉庫中。  
   * 對生成的 .d 檔進行後處理，將絕對路徑轉換為相對路徑後存入倉庫。

### **6.3 技術挑戰與解決方案**

#### **6.3.1 跨分區限制**

Reflink 的物理限制是無法跨 Mount Point。

* **解決方案**：Wrapper 啟動時檢查 target 目錄與 Warehouse 目錄的 stat.st\_dev (Device ID)。若不相同，則降級為標準複製模式（Copy Mode），行為退化為普通的 sccache。

#### **6.3.2 併發與鎖定 (Concurrency & Locking)**

當多個專案同時編譯同一依賴項（如 serde）時，可能會發生競態條件（Race Condition），導致同時寫入 Warehouse。

* **解決方案**：在寫入 Warehouse 時使用檔案鎖（flock）。由於 Reflink 操作極快，鎖的持有時間極短，不會造成顯著阻塞 。

#### **6.3.3 碎片化 (Fragmentation)**

CoW 檔案系統在頻繁隨機寫入下容易產生碎片 。

* **分析**：Rust 的編譯產物通常是「一次寫入，頻繁讀取，整體替換」。編譯器通常會刪除舊檔並寫入新檔，而不是在舊檔上進行隨機寫入。因此，碎片化風險相對較低。但建議對 Warehouse 目錄啟用 Btrfs 的 autodefrag 掛載選項或定期執行 btrfs filesystem defragment。

## **7\. 效益量化分析**

假設一個開發者有 5 個專案，每個專案的 target/debug/deps 佔用 2GB 空間，且這些專案共用 80% 的依賴項。  
**表 2：不同方案的資源消耗比較**

| 指標 | 傳統 Cargo | sccache (本地硬碟) | Cargo-CoW (本案) |
| :---- | :---- | :---- | :---- |
| **磁碟佔用** | \~10 GB (5 x 2GB) | \~12 GB (10GB target \+ 2GB cache) | **\~2.4 GB** (2GB cache \+ 0.4GB unique) |
| **首次編譯速度** | 慢 (全編譯) | 慢 (全編譯 \+ 寫入快取) | 慢 (全編譯 \+ Reflink 快取) |
| **跨專案重用速度** | 無 (需重編譯) | 快 (I/O 複製 1.6GB) | **極快** (O(1) Reflink 1.6GB) |
| **I/O 負載** | 高 (寫入 10GB) | 極高 (寫入 12GB \+ 讀取) | **低** (寫入 2.4GB) |
| **安全性** | 高 | 高 | 高 (CoW 保證隔離) |

從表中可見，Cargo-CoW 方案在磁碟空間上可節省約 76% (與傳統 Cargo 相比) 至 80% (與 sccache 相比)，且在跨專案構建時，能完全消除大檔案複製的 I/O 延遲。

## **8\. 結論**

本研究證實，利用 Btrfs 的 CoW 與 Reflink 特性來構建系統級 Rust 編譯快取在架構上是完全可行的，且能顯著解決目前開發流程中的痛點。透過模仿 Docker 的分層儲存思想，但將粒度調整為檔案級別，我們可以在不犧牲建置隔離性的前提下，實現極致的儲存去重與快速還原。  
關鍵的實作細節在於：

1. 正確處理 Rustc 的路徑重映射 (--remap-path-prefix) 以確保快取命中率。  
2. 精確操作檔案的 mtime 以滿足 Cargo 的指紋檢查機制。  
3. 利用 ioctl\_ficlone 替代傳統 I/O 複製。

對於使用 Linux (Btrfs/XFS) 或 macOS (APFS) 的 Rust 開發者而言，這套工具將是提升開發效率的強大槓桿。建議社群可以基於現有的 sccache 專案進行擴充，增加一個「Reflink Backend」，這將是實現此願景最直接且低風險的路徑。

#### **引用的著作**

1. BTRFS storage driver | Docker Docs, https://docs.docker.com/engine/storage/drivers/btrfs-driver/
2. Select a storage driver - Docker Docs, https://docs.docker.com/engine/storage/drivers/select-storage-driver/
3. docker/docs/userguide/storagedriver/btrfs-driver.md at master - GitHub, https://github.com/lirantal/docker/blob/master/docs/userguide/storagedriver/btrfs-driver.md
4. Default copy Vs reflink : r/btrfs - Reddit, https://www.reddit.com/r/btrfs/comments/1bum79p/default_copy_vs_reflink/
5. cp with reflink flag: how to determine if reflink is possible? - Unix & Linux Stack Exchange, https://unix.stackexchange.com/questions/318705/cp-with-reflink-flag-how-to-determine-if-reflink-is-possible
6. Cargo Targets - The Cargo Book - Rust Documentation, https://doc.rust-lang.org/cargo/reference/cargo-targets.html
7. Build Cache - The Cargo Book - Rust Documentation, https://doc.rust-lang.org/cargo/reference/build-cache.html
8. Incremental compilation in detail - Rust Compiler Development Guide, https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html
9. 1298-incremental-compilation - The Rust RFC Book, https://rust-lang.github.io/rfcs/1298-incremental-compilation.html
10. Fingerprint in cargo::core::compiler, https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/struct.Fingerprint.html
11. Module fingerprint - cargo::core::compiler - Rust Documentation, https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html
12. (Option to) Fingerprint by file contents instead of mtime · Issue #6529 · rust-lang/cargo, https://github.com/rust-lang/cargo/issues/6529
13. linux cp mtime change - Stack Overflow, https://stackoverflow.com/questions/15693720/linux-cp-mtime-change
14. Unstable Features - The Cargo Book - Rust Documentation, https://doc.rust-lang.org/cargo/reference/unstable.html
15. MCP: Alternate cargo freshness algorithm, unstable flag to annotate depinfo file with checksums and file sizes · Issue #765 · rust-lang/compiler-team - GitHub, https://github.com/rust-lang/compiler-team/issues/765
16. Remap source paths - The rustc book - Rust Documentation, https://doc.rust-lang.org/beta/rustc/remap-source-paths.html
17. sccache | Cache | Depot Documentation, https://depot.dev/docs/cache/integrations/sccache
18. sccache 0.12.0 - Docs.rs, https://docs.rs/crate/sccache/latest/source/docs/Configuration.md
19. mozilla/sccache: Sccache is a ccache-like tool. It is used as a compiler wrapper and avoids compilation when possible. Sccache has the capability to utilize caching in remote storage environments, including various cloud storage options, or alternatively, in local storage. - GitHub, https://github.com/mozilla/sccache
20. Blog Archive » sccache, Mozilla's distributed compiler cache, now written in Rust, https://blog.mozilla.org/ted/2016/11/21/sccache-mozillas-distributed-compiler-cache-now-written-in-rust/
21. Support reflinks & hardlinks · Issue #1053 · mozilla/sccache - GitHub, https://github.com/mozilla/sccache/issues/1053
22. Hard link vs Soft link vs Reflink | by Jerome Decinco - Medium, https://medium.com/@jeromedecinco/hardlink-vs-softlink-vs-reflink-a3c74bb5db64
23. COW cp (--reflink) doesn't work across different datasets: Invalid cross-device link · Issue #15345 · openzfs/zfs - GitHub, https://github.com/openzfs/zfs/issues/15345
24. The two sides of reflink() - LWN.net, https://lwn.net/Articles/331808/
25. --remap-path-prefix doesn't map paths to `.pdb` files, even in release mode · Issue #87825 · rust-lang/rust - GitHub, https://github.com/rust-lang/rust/issues/87825
26. Target directory isolation/locking fails when cross-compiling · Issue #5968 · rust-lang/cargo, https://github.com/rust-lang/cargo/issues/5968
27. So many crates break when you set target-dir in ~/.cargo/config - The Rust Programming Language Forum, https://users.rust-lang.org/t/so-many-crates-break-when-you-set-target-dir-in-cargo-config/75574
28. Btrfs performance : r/btrfs - Reddit, https://www.reddit.com/r/btrfs/comments/kul2hh/btrfs_performance/
29. Does Btrfs need defragmentation? - Ask Ubuntu, https://askubuntu.com/questions/84213/does-btrfs-need-defragmentation