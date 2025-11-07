# **技術可行性報告：運用 Btrfs 寫入時複製機制加速 Rust 建置快取**

## **第一節：核心技術深度剖析**

本節旨在對專案構想中所涉及的各項核心技術進行深入解構，建立對其基本原理的詳盡理解。此基礎分析將為後續章節的綜合評估提供必要的技術背景。

### **1.1 Btrfs 檔案系統：一個原生支援 CoW 的架構**

Btrfs 的核心設計理念是寫入時複製（Copy-on-Write, CoW），此特性是其所有進階功能的基石 。

* **核心原理：寫入時複製 (CoW)** 當檔案系統中的資料被修改時，Btrfs 並不會直接覆寫原始的資料區塊。相反，它會將修改後的內容寫入一個新的區塊，然後更新檔案系統的中繼資料（metadata）以指向這個新位置。這個機制確保了原始資料的完整性，並為快照（snapshot）與 reflink 等功能提供了實現基礎。  
* **子磁區 (Subvolumes) 與快照 (Snapshots)** Btrfs 檔案系統能夠包含多個子磁區，這些子磁區可以被視為獨立且可掛載的檔案系統樹 。快照是一種特殊的子磁區，它在建立之初與其來源子磁區共享所有資料區塊 。因此，建立快照幾乎是一個瞬時完成的中繼資料操作，因為過程中不涉及任何實體資料的複製 。 當來源子磁區或快照中的任何檔案被修改時，CoW 機制會確保只有被修改的資料區塊被複製一份，從而保留原始區塊給未修改的一方。這種「分歧」的過程使得快照在極度節省空間的同時，能作為一個精確的時間點備份 。快照可以是唯讀或可讀寫的。  
* **Reflinks (檔案層級的 CoW)** Reflink 是一種檔案層級的 CoW 操作，通常透過 cp \--reflink 指令來使用 。它會建立一個新的、獨立的檔案條目，但該檔案初始時與來源檔案共享其所有的資料區塊 。與快照相似，這是一個速度極快且僅消耗極少初始空間的中繼資料操作 。當任一 reflink 檔案被修改時，CoW 機制會將變動隔離在該檔案內，僅複製必要的資料區塊 。 一個關鍵的區別在於：快照操作於子磁區（即目錄樹）層級，並且是**原子性**的，能夠在單一瞬間捕捉整個目錄樹的狀態 。而 Reflink 則操作於檔案層級，當應用於整個目錄時（如 cp \-r \--reflink），它是一系列獨立的檔案操作，不具備原子性 。

### **1.2 Docker 的儲存引擎與 Btrfs 驅動程式**

Docker 的映像檔由多個唯讀層堆疊而成，而容器則是在最上層添加一個輕薄的可寫層。儲存驅動程式的職責是將這些分層呈現為一個單一、連貫的檔案系統（即聯合檔案系統）。所有 Docker 儲存驅動程式都利用 CoW 策略來優化儲存空間與容器啟動時間 。

* **Btrfs 驅動程式的實現** btrfs 儲存驅動程式將 Docker 的抽象概念直接對應到 Btrfs 的原生功能上 ：  
  * **映像檔分層 (Image Layers)：** 每個映像檔層被儲存為一個唯讀的 Btrfs 子磁區 。  
  * **容器 (Containers)：** 當一個容器被建立時，Docker 會為該映像檔最終層的子磁區建立一個新的、可讀寫的 Btrfs **快照**。這個快照便成為容器的可寫層 。  
* **Docker 中的 CoW 工作流程**  
  1. **讀取存取：** 當容器讀取一個存在於底層映像檔中的檔案時，它直接存取由其快照所共享的資料區塊，此過程不發生任何資料複製 。  
  2. **寫入存取 (修改)：** 當容器首次修改一個已存在的檔案時，Btrfs 的 CoW 機制被觸發。相關的資料區塊被複製到容器的快照中（概念上稱為 "copy-up" 操作），然後修改被應用於這個新的複本。原始映像檔層的子磁區則保持不變 。  
  3. **新檔案建立：** 在容器內建立的新檔案會被直接寫入其可讀寫的快照中 。  
* **組態設定** 要使用 btrfs 驅動程式，需要進行特定的設定，包括使用 Btrfs 格式化一個專用的區塊儲存裝置，並將其掛載到 /var/lib/docker 。同時，必須在 Docker 的 daemon.json 設定檔中明確指定使用 btrfs 驅動程式 。

### **1.3 Rust 的編譯生命週期與內部快取機制**

* **target 目錄** 此目錄是 Rust 建置快取的核心。它包含了已編譯的相依性套件 (deps)、增量編譯資料 (incremental)、建置腳本的輸出 (build)，以及最終的產出物（例如，位於 debug 或 release 目錄中）。  
* **增量編譯即查詢系統** Rust 的增量編譯是一個高度精密的系統，其設計目標是最大限度地減少重複計算工作 。它並非簡單的檔案時間戳檢查。  
  * 它將編譯過程模型化為一個由查詢組成的有向無環圖 (DAG)，其中每個查詢都是一個純函數（相同的輸入永遠產生相同的輸出）。  
  * 它採用一種「紅綠」(red-green) 演算法來追蹤相依性。當原始碼檔案變更時，系統會沿著圖追蹤其影響。如果一個節點（即查詢結果）的輸入未變，或者重新計算後的結果與快取中的一致，該節點就會被標記為「綠色」(green)。只有依賴於「紅色」(red，即已變更) 節點的節點才需要被重新評估 。  
  * 這個相依性圖以及查詢結果會被持久化到磁碟上的 target/incremental 目錄內，形成一個複雜的資料庫，這對於實現快速的重新建置至關重要 。  
* **管線化編譯 (Pipelined Compilation)** Cargo 一個規劃中的未來優化是「管線化編譯」。其概念是，一個依賴其他套件 (A) 的套件 (B)，可以在 A 產生其中繼資料後就開始編譯，而無需等待 A 的完整編譯過程結束。這突顯了中間編譯狀態的重要性，並旨在提升建置的平行度 。

### **1.4 sccache：一個外部共享編譯快取工具**

* **架構概覽** sccache 是一個編譯器包裝器 (compiler wrapper)，它攔截編譯指令，檢查是否存在快取的結果。如果存在，則直接返回快取的產物；否則，它會調用真正的編譯器，並將新的結果儲存起來 。它是 ccache 的精神繼承者，使用 Rust 重寫以獲得更好的並行處理能力，並增加了對分散式快取與編譯的支援 。  
* **透過 RUSTC\_WRAPPER 整合** Cargo 提供了一個環境變數 RUSTC\_WRAPPER（或可透過設定檔 build.rustc-wrapper 指定）。當設定此變數後，Cargo 會調用該包裝器程式而非直接執行 rustc，並將原始的 rustc 指令行作為參數傳遞 。這是 sccache 與 Rust 建置流程整合的主要機制。  
* **快取鍵 (Cache Key) 的產生** sccache 透過對特定編譯單元的所有輸入進行雜湊指紋運算來產生快取鍵。這些輸入包括原始碼、編譯器旗標、相關的環境變數以及編譯器本身的二進位檔 。這種內容定址 (content-addressable) 的方法確保了快取是全域無衝突的，並且快取命中 (cache hit) 必然保證產出是完全相同的 。  
* **客戶端-伺服器模型 (Client-Server Model)** sccache 會在本機執行一個伺服器程序，用以在記憶體中管理快取狀態，這比每次編譯器調用都重新初始化更有效率 。命令列工具則作為客戶端與此本機伺服器進行通訊。  
* **儲存後端 (Storage Backends)** sccache 具有高度的靈活性，除了支援本地磁碟儲存 (SCCACHE\_DIR) 外，還支援多種遠端後端，包括 S3、Google Cloud Storage、Azure Blob Storage、Redis 和 WebDAV 。這使其非常適合在持續整合 (CI) 環境中跨機器共享快取 。

這三種快取機制運作在根本不同的抽象層次上。Rust 的增量編譯處於最精細的層級，它理解 Rust 語言的內部語義及其查詢相依圖，快取的是 MIR 和型別資訊等中間表示 。sccache 則運作於編譯器調用層級，將 rustc 視為一個黑盒子，僅關心輸入（原始檔、旗標）與輸出（目標檔）之間的轉換，對 Rust 內部的相依圖一無所知 。而本專案構想的 Btrfs 快照機制則運作於檔案系統區塊層級，它對其快取的內容完全無知，僅僅是保存 target 目錄樹的狀態。  
這種層次上的差異揭示了一個潛在的協同作用：Btrfs 快照能夠完美地保存最精細層級的快取（Rust 的增量編譯資料），而這正是 sccache 這類編譯器層級的快取工具完全無法觸及的。這構成了本專案的核心假設。Docker 對 Btrfs 的使用提供了一個強而有力的、經過生產環境驗證的類比。Docker 將「映像檔分層」這一抽象概念對應到「Btrfs 子磁區」這個具體的檔案系統功能上，並將「容器的可寫狀態」對應到「Btrfs 快照」。本專案提出了一個類似的對應關係：將「特定分支/提交的快取建置狀態」這一抽象概念，對應到「target 目錄的 Btrfs 快照」這一具體功能。因此，Docker Btrfs 驅動程式的穩定性與效能，可作為此底層技術用於透過快照管理狀態之可行性的參考指標。

## **第二節：效能剖析與比較基準測試**

本節將理論概念與實證數據相結合，以評估在類似於程式碼編譯的工作負載下，Btrfs 的實際效能表現。

### **2.1 Btrfs 相較於 ext4/xfs 的效能特性**

Phoronix 進行的基準測試提供了一個有價值的間接比較 。

* **中繼資料密集型工作負載 (以 SQLite 為例)** 在單執行緒的 SQLite 寫入測試中，Btrfs 的表現最慢，顯著落後於 xfs 和 ext4。然而，隨著並行執行緒數的增加，其效能變得更具競爭力 。這暗示著，建置過程中涉及大量小型、同步中繼資料更新的步驟（例如更新增量快取資料庫）可能會成為效能瓶頸。  
* **隨機 I/O (以 FIO 為例)** 對於 4K 隨機讀取，Btrfs 表現處於中等水準。而在隨機寫入方面，xfs 則處於領先地位 。Rust 的建置過程涉及大量的隨機 I/O，因為它需要讀取原始碼、相依性套件，並寫入目標檔與中繼資料。  
* **高並行 I/O (以 Dbench 為例)** 在使用 12 個客戶端的 Dbench 基準測試下，Btrfs 取得了強勢的第一名 。這是一個非常有前景的結果，因為一個平行的 Rust 建置 (-jN) 正是一個高度並行的工作負載。  
* **整體幾何平均值** 綜合所有測試，xfs 是明顯的效能冠軍，而 ext4 與 Btrfs 並列第三 。這表明 Btrfs 雖有其優勢，但在所有類型的工作負載下並非全面的效能領先者。

Btrfs 的效能表現出高度的工作負載依賴性。Phoronix 的數據顯示，它在單執行緒、中繼資料密集的任務中表現不佳，但在高度並行的 I/O 場景中卻表現出色 。Rust 的建置過程並非單一模式，它包含了不同的 I/O 型態。初始的相依性解析與圖構建可能類似前者，而平行編譯 crates 的階段則更像後者。這意味著使用 Btrfs 可能會加速建置中高度平行的部分，但同時可能拖慢單執行緒、中繼資料密集的部分。最終的淨效應並不明顯，必須透過概念驗證 (PoC) 進行實證。

**表 1：Btrfs 與其他檔案系統效能摘要 (基於 Linux 6.15)**

| 檔案系統 | SQLite (1 執行緒) | SQLite (8 執行緒) | FIO 4K 隨機讀取 | FIO 4K 隨機寫入 | Dbench (12 客戶端) | 整體幾何平均值 |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- |
| **Btrfs** | 最慢 | 具競爭力 | 中等 | 未明確，落後 XFS | **第一名** | 第三名 (與 ext4 並列) |
| **ext4** | 領先 Btrfs | 未明確 | 領先群 | 未明確，落後 XFS | 落後 Btrfs | 第三名 (與 Btrfs 並列) |
| **xfs** | 領先 | 落後 F2FS | 領先群 | **領先** | 落後 Btrfs | **第一名** |
| **F2FS** | 領先 Btrfs | **第一名** | 領先群 | 未明確，落後 XFS | 落後 Btrfs | 第二名 |
| **Bcachefs** | 慢於 XFS/ext4 | 第二名 | 最慢 | 最慢 | 落後 Btrfs | 最末名 |

* **對大量小檔案的考量** 處理大量小檔案的工作負載對 Btrfs 而言可能具有挑戰性。有證據顯示，由於中繼資料的關係，會產生顯著的空間開銷，儘管某些報告的問題可能與 Samba 等外部工具錯誤回報區塊分配有關，而非檔案系統的根本缺陷 。關於效能的基準測試結果好壞參半。一項測試指出，在這種情境下 Btrfs 提供了比 ext4 和 xfs 更高的效能 ，而其他討論則認為在 SSD 上的效能差異可以忽略不計，但在 HDD 上則會因碎片化而受影響 。target 目錄正是典型的「大量小檔案」問題場景。

值得注意的是，Btrfs 仍在積極開發中，近期的 Linux 核心已為其帶來了針對中繼資料密集型操作和循序讀取的顯著效能改進 。任何概念驗證都必須在較新的 Linux 核心上進行。

### **2.2 CoW 操作的效能：reflink vs. 快照**

* **建立速度** 無論是建立子磁區的快照，還是建立檔案的 reflink，都被描述為近乎瞬時的操作。它們主要涉及寫入新的中繼資料，而非複製資料區塊 。現有資料中沒有基準測試表明兩者在其各自的粒度上有顯著的效能差異。  
* **原子性與粒度** 關鍵的差異不在於速度，而在於功能。btrfs subvolume snapshot 是對整個目錄樹的原子性操作 。這對於捕捉 target 目錄的一致性狀態至關重要，因為其中的多個檔案是相互關聯的。相比之下，cp \-r \--reflink 則是一系列非原子性的檔案操作 。如果在建置過程中並行執行，可能會導致快取狀態不一致、部分複製的問題。  
* **使用場景的適用性** 對於本專案旨在快取整個 target 目錄的目標而言，快照的原子性與目錄層級的特性使其成為技術上無疑優於檔案層級 reflink 的選擇。

**表 2：Btrfs CoW 操作比較**

| 屬性 | btrfs subvolume snapshot | cp \--reflink |
| :---- | :---- | :---- |
| **粒度** | 子磁區 (目錄樹) | 檔案 |
| **原子性** | 是，單一瞬間操作 | 否，對目錄是循序檔案操作 |
| **建立速度** | 近乎瞬時 (中繼資料操作) | 近乎瞬時 (中繼資料操作) |
| **主要用途** | 建立時間點備份、系統還原點 | 快速、節省空間的檔案複製 |
| **資料依賴** | 新快照依賴於來源子磁區的共享區塊 | 新檔案依賴於來源檔案的共享區塊 |

## **第三節：一個由 Btrfs 驅動的 Rust 建置快取框架**

本節將前述的分析綜合為一個具體的專案提案，闡述一個能夠利用 Btrfs 快照獨特優勢的工作流程與架構。

### **3.1 概念性工作流程與架構：快照交換模型**

* **核心概念** 此模型的核心思想並非從快取中逐一獲取檔案，而是透過 Btrfs 快照，以原子性的方式將整個 target 目錄替換為一個預先存在的、已知的良好狀態。  
* **先決條件** 專案的原始碼與 target 目錄必須位於同一個 Btrfs 檔案系統上，理想情況下應位於一個專用的子磁區內，以便於管理。  
* **建議工作流程**  
  1. **基準快照建立：** 在主分支上成功完成一次全新建置後，為 target 子磁區建立一個唯讀快照。例如：btrfs subvolume snapshot \-r target target.main.clean。  
  2. **開發開始：** 當開發者開始工作時（例如，切換到一個功能分支），從最相關的基準快照建立一個新的可讀寫快照。例如：btrfs subvolume snapshot target.main.clean target.feature-branch。這個新快照將成為當前活躍的 target 目錄。  
  3. **增量建置：** 所有後續的 cargo build 指令都在這個可讀寫的快照 (target.feature-branch) 中進行，完美地利用 Rust 原生的增量編譯功能。  
  4. **情境切換 (例如 git checkout main)：** 建置協調腳本將執行以下操作： a. 卸載或重新命名當前的 target.feature-branch。 b. 掛載或重新命名 target.main.clean 快照（或其一個可讀寫的複本）成為活躍的 target。 c. 這個操作是近乎瞬時的。下一次在 main 分支上執行的 cargo build 將會是一個「空建置」(null build)，耗時極短。  
  5. **快取提升：** 當一個功能分支成功建置並通過測試後，其 target 快照可以被「提升」為一個新的基準快照，供其他開發相同功能的開發者使用。

### **3.2 與原生及外部快取的互動：一個多層次快取體系**

* **第 0 層 (檔案系統狀態快取)：** Btrfs 快照模型。其優勢在於對整個建置目錄提供完美的狀態保真度，以及近乎零成本的還原時間。  
* **第 1 層 (增量編譯快取)：** 位於 target/incremental 內的 Rust 原生增量快取。第 0 層 Btrfs 快取的主要效益，正在於跨情境切換時能夠完整地保護第 1 層快取的完整性 。  
* **第 2 層 (共享目標檔快取)：** sccache。對於從相依性套件產生新的編譯產物，或在不共享 Btrfs 磁區的專案間共享產物，sccache 仍然具有價值 。

此模型並非要取代 sccache，而是與之互補。一個混合式的方法可能是最佳的：使用 Btrfs 快照進行本地開發的情境切換，同時使用帶有遠端後端（如 S3）的 sccache 進行 CI 建置和初始快取填充。Btrfs 快照還原狀態後，後續的建置可以利用 sccache 快速編譯少量已變更的檔案，並從其他開發者或 CI 運作所填充的快取中獲益。

### **3.3 利益與風險的先期評估**

* **潛在利益**  
  * **近乎瞬時的情境切換：** 大幅減少因 git checkout 而導致的懲罰，目前這種操作會使大部分增量快取失效。  
  * **完美的快取保真度：** 消除因不完整或部分獲取的快取而可能引發的細微問題。還原的狀態與先前儲存的狀態在位元層級上完全相同。  
  * **減少網路 I/O：** 對於本地開發，這避免了從遠端 sccache 後端獲取成千上萬個小檔案，這個過程可能因每個請求的延遲開銷而變得緩慢 。  
* **潛在風險**  
  * **檔案系統鎖定：** 此解決方案與 Btrfs 深度綁定，限制了其在其他檔案系統（如 ext4、xfs 或 macOS 上的 APFS）上的可移植性 。  
  * **協調的複雜性：** 需要客製化的腳本來管理快照的生命週期（建立、交換、提升、修剪）。這比為 sccache 設定一個環境變數要複雜得多。  
  * **儲存開銷：** 雖然快照在初始時節省空間，但隨著時間推移和變更的累積，舊快照會阻止區塊被釋放，可能導致顯著的磁碟空間佔用。需要一個穩健的修剪策略。  
  * **效能病灶：** 如第二節所分析，Btrfs 在某些編譯固有的 I/O 模式下可能表現不佳，即使它解決了情境切換的問題，也可能引入新的效能瓶頸。

## **第四節：可行性驗證與實作評估**

本節提供了一個實際可行的路徑，用以測試專案假設並評估其在生產環境中所需的工程投入。

### **4.1 概念驗證 (PoC) 藍圖**

* **環境設定**  
  1. 準備一台裝有近期 Linux 核心（例如 6.x 或更新版本，以利用最新的效能改進 ）的虛擬機。  
  2. 建立一個專用區塊裝置並使用 mkfs.btrfs 進行格式化 。  
  3. 將此裝置掛載到一個工作路徑，例如 /build。  
  4. 為專案建立一個頂層子磁區：btrfs subvolume create /build/my-rust-project。  
  5. 在此子磁區內，為建置產物建立一個專用子磁區：btrfs subvolume create /build/my-rust-project/target。target 目錄必須是其自身的子磁區才能被快照。  
* **協調腳本 (例如，使用 Bash 或 Python)**  
  * 為關鍵操作開發函數：  
    * create\_snapshot(source, dest, read\_only=true)  
    * activate\_cache(snapshot\_name)：此函數將涉及重新命名或重新掛載子磁區，使指定的快照成為活躍的 /build/my-rust-project/target。  
    * prune\_snapshots(policy)：一個用來刪除舊的或未使用的快照的函數。  
  * 將這些函數整合到一個包裝腳本中，該腳本可由 git hooks（例如 post-checkout）觸發或手動執行。  
* **測試案例與測量** 選擇一個具有中等至大型規模且相依樹不簡單的 Rust 專案。  
  1. **基準測試：** git checkout main; rm \-rf target; time cargo build。  
  2. **快照建立：** create\_snapshot("target", "main-cache")。  
  3. **空建置測試：** time cargo build (應在數秒內完成)。  
  4. **微小變更測試：** git checkout \-b feature-a; activate\_cache("main-cache"); 修改一個原始檔；time cargo build。  
  5. **分支切換測試 (關鍵場景)：** git checkout main; activate\_cache("main-cache"); time cargo build。將此時間與僅使用 sccache（在 cargo clean 之後）的相同工作流程進行比較。  
  6. **相依性變更測試：** git checkout \-b feature-b; activate\_cache("main-cache"); 在 Cargo.toml 中新增一個 crate；time cargo build。  
* **工具** 使用如 hyperfine 等工具對建置指令進行嚴謹的基準測試。使用 btrfs filesystem usage 監控磁碟空間使用情況。

### **4.2 關鍵指標與成功標準**

* **主要指標：** 在兩個差異顯著的分支之間執行 git checkout 後的重新建置時間。  
  * **成功標準：** 相較於一個溫快取 (warm cache) 的 sccache（本地磁碟後端），Btrfs 快照方法必須將此時間減少至少 50%；相較於冷快取 (cold cache)，則需減少至少 80%。  
* **次要指標：**  
  * 經過 20 次以上的快照建立/刪除循環後的磁碟空間消耗。  
  * 快照管理操作本身所花費的時間（應可忽略不計）。  
  * 關於流程透明度與可靠性的質化開發者回饋。

### **4.3 實作難度評估**

* **基礎設施設定：高** 需要特定的主機作業系統 (Linux)、檔案系統 (Btrfs) 和分割區方案。不易移植到 macOS 或 Windows 開發者機器上，使其主要成為標準化 CI/CD 環境或純 Linux 開發團隊的解決方案。  
* **建置協調：高** 需要客製化且穩健的腳本來管理快照的生命週期。此邏輯必須整合到 CI 管線和潛在的開發者工具（如 git hooks）中，並且必須對錯誤具有韌性（例如，失敗的建置不應使快取處於損壞狀態）。  
* **開發者體驗：中** 如果能無縫整合到 CI 中，對使用者是透明的。對於本地開發，則需要開發者採用 Btrfs 設定並使用包裝腳本，這增加了額外的摩擦。  
* **長期維護：中** 需要監控 Btrfs 的磁碟空間與中繼資料健康狀況。快照修剪策略需要精心設計與維護，以防止磁碟使用量無限制增長。

## **第五節：結論與策略性建議**

本節將提供一個基於證據的清晰結論，對專案的可行性做出最終判斷。

### **5.1 研究發現總結**

* 使用 Btrfs 快照來快取 Rust target 目錄的提議架構在技術上是合理的，並且與 Docker 在生產環境中使用 btrfs 儲存驅動程式的情況相類似。  
* 其主要的理論優勢在於能夠作為一個「第 0 層」快取，完美地保存 Rust 自身高度優化的增量編譯資料庫的狀態，這是像 sccache 這類編譯器包裝器快取工具無法實現的。  
* 此優勢在涉及頻繁、大規模情境切換的工作流程中（例如在 Git 儲存庫中切換分支）最為顯著。  
* 然而，採用此解決方案會帶來顯著的實作複雜性、對 Btrfs 檔案系統的硬性依賴，以及潛在的效能權衡，因為 Btrfs 在所有與編譯相關的 I/O 模式中並非全面的效能領先者。

### **5.2 最終建議**

所提議的基於 Btrfs 的快取機制呈現了一個**高風險、高回報**的機會。在情境切換後實現近乎瞬時建置的潛力，是一個顯著的生產力倍增器，但其伴隨的實作成本與平台限制也相當巨大。  
**建議：繼續推進所規劃的概念驗證 (PoC)。** PoC 對於量化驗證所假設的效能增益，以及揭示 Btrfs 在真實 Rust 編譯工作負載下任何未預見的效能病灶至關重要。PoC 的結果應成為決定是否進行更廣泛、生產級別實作的唯一依據。初步的重點應放在 CI 環境，因為在這些環境中，基礎設施可以被標準化和控制。

#### **引用的著作**

1. **BTRFS storage driver | Docker Docs**  
   https://docs.docker.com/engine/storage/drivers/btrfs-driver/

2. **Docker and Layers - Reddit**  
   https://www.reddit.com/r/docker/comments/69at69/docker_and_layers/

3. **Btrfs: Difference between snapshotting and cp --reflink : r/linuxquestions - Reddit**  
   https://www.reddit.com/r/linuxquestions/comments/p7wx4j/btrfs_difference_between_snapshotting_and_cp/

4. **Reflink - BTRFS documentation - Read the Docs**  
   https://btrfs.readthedocs.io/en/latest/Reflink.html

5. **Default copy Vs reflink : r/btrfs - Reddit**  
   https://www.reddit.com/r/btrfs/comments/1bum79p/default_copy_vs_reflink/

6. **The two sides of reflink() - LWN.net**  
   https://lwn.net/Articles/331808/

7. **Hard links vs cp --reflink on BTRFS to save space : r/synology - Reddit**  
   https://www.reddit.com/r/synology/comments/jupa14/hard_links_vs_cp_reflink_on_btrfs_to_save_space/

8. **Storage drivers - Docker Docs**  
   https://docs.docker.com/engine/storage/drivers/

9. **Docker Image Layers - What They Are & How They Work - Spacelift**  
   https://spacelift.io/blog/docker-image-layers

10. **Understand images, containers, and storage drivers - Why Docker? - Read the Docs**  
    https://test-dockerrr.readthedocs.io/en/latest/userguide/storagedriver/imagesandcontainers/

11. **According to the union file system, does image actually container another image? - Stack Overflow**  
    https://stackoverflow.com/questions/47946898/according-to-the-union-file-system-does-image-actually-container-another-image

12. **Storage | Docker Docs**  
    https://docs.docker.com/engine/storage/

13. **Select a storage driver - Docker Docs**  
    https://docs.docker.com/engine/storage/drivers/select-storage-driver/

14. **Incremental Rust builds in CI - Earthly Blog**  
    https://earthly.dev/blog/incremental-rust-builds/

15. **Incremental Compilation | Rust Blog**  
    https://blog.rust-lang.org/2016/09/08/incremental.html

16. **Incremental compilation in detail - Rust Compiler Development Guide**  
    https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html

17. **Implement "pipelined" rustc compilation · Issue #6660 · rust-lang/cargo - GitHub**  
    https://github.com/rust-lang/cargo/issues/6660

18. **Why You Need Sccache - Elijah Potter**  
    https://elijahpotter.dev/articles/why_you_need_sccache

19. **Optimizing Rust Build Speed with sccache - Earthly Blog**  
    https://earthly.dev/blog/rust-sccache/

20. **mozilla/sccache: Sccache is a ccache-like tool - GitHub**  
    https://github.com/mozilla/sccache

21. **Buildless + SCCache**  
    https://docs.less.build/docs/sccache

22. **Blog Archive » sccache, Mozilla's distributed compiler cache, now written in Rust**  
    https://blog.mozilla.org/ted/2016/11/21/sccache-mozillas-distributed-compiler-cache-now-written-in-rust/

23. **Environment Variables - The Cargo Book - MIT**  
    https://web.mit.edu/rust-lang_v1.25/arch/amd64_ubuntu1404/share/doc/rust/html/cargo/reference/environment-variables.html

24. **What is the difference between Cargo's environment variables RUSTC and RUSTC_WRAPPER? - Stack Overflow**  
    https://stackoverflow.com/questions/50446200/what-is-the-difference-between-cargos-environment-variables-rustc-and-rustc-wra

25. **Environment Variables - The Cargo Book - Rust Documentation**  
    https://doc.rust-lang.org/cargo/reference/environment-variables.html

26. **Configuration - The Cargo Book - Rust Documentation**  
    https://doc.rust-lang.org/cargo/reference/config.html

27. **2023-04: Why should you give Sccache a try? - Xuanwo's Blog**  
    https://xuanwo.io/en-us/reports/2023-04/

28. **sccache is ccache with cloud storage - GitHub**  
    https://github.com/wasmerio/sccache

29. **Fast Rust Builds with sccache and GitHub Actions - Depot.dev**  
    https://depot.dev/blog/sccache-in-github-actions

30. **Bcachefs, Btrfs, EXT4, F2FS & XFS File-System Performance On Linux 6.15 - Phoronix**  
    https://www.phoronix.com/review/linux-615-filesystems/2

31. **BTRFS + many small files = heavy space wasted - Reddit**  
    https://www.reddit.com/r/btrfs/comments/m9qsi3/btrfs_many_small_files_heavy_space_wasted/

32. **which file sytem to use for daily work? should we turn on btrfs compression? - GitHub Gist**  
    https://gist.github.com/braindevices/fde49c6a8f6b9aaf563fb977562aafec

33. **btrfs vs ext4 performance - Reddit**  
    https://www.reddit.com/r/btrfs/comments/14y99p2/btrfs_vs_ext4_performance/

34. **Btrfs Preps Performance Improvements & Experimental Large Folios For Linux 6.17 - Phoronix**  
    https://www.phoronix.com/news/Linux-6.17-Btrfs

35. **Btrfs To See More Performance Improvements With Linux 6.16 - Phoronix**  
    https://www.phoronix.com/news/Linux-6.16-Btrfs-Performance

36. **Distributed compilation with sccache - rtyler**  
    https://brokenco.de/2025/01/05/sccache-distributed-compilation.html

37. **In Linux, which filesystems support reflinks? - Unix & Linux Stack Exchange**  
    https://unix.stackexchange.com/questions/631237/in-linux-which-filesystems-support-reflinks