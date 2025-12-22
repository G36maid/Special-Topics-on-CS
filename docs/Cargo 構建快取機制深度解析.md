# **Cargo 內部架構深度剖析：構建系統、依賴圖譜與快取機制之完整研究**

## **1\. 緒論：現代化構建系統的複雜性與設計哲學**

在現代軟體工程的領域中，套件管理器與構建系統的角色已遠超出了單純的編譯調用工具。作為 Rust 程式語言生態系的核心支柱，Cargo 的設計不僅是為了自動化 rustc 的執行，更是一個精密的依賴解析、生命週期管理與任務編排引擎。其內部架構展示了如何在強型別系統的約束下，處理從簡單的單一檔案到包含數百個微服務、跨平台目標與複雜條件編譯的大型單體倉庫（Monorepo）的構建需求。  
深入探究 Cargo 的原始碼層面，特別是其核心編譯器模組 src/cargo/core/compiler，揭示了一套以「單元（Unit）」為原子操作、以「指紋（Fingerprint）」為快取依據、並透過有向無環圖（DAG）進行並行調度的複雜系統。本研究報告旨在詳盡解構 Cargo 的內部運作機制，從最基礎的資料結構定義，到宏觀的構建流水線（Pipelining）策略，全面剖析其如何實現高效的增量編譯與快取管理。  
Cargo 的設計哲學深受「正確性優先，兼顧效能」的原則驅動。與 Make 或 CMake 等傳統構建系統不同，Cargo 深度整合了語言特性。它理解 Rust 的模組系統、Feature 標記的聯集邏輯以及編譯器產生的元數據（Metadata）。這種深度整合使得 Cargo 能夠執行細粒度的依賴追蹤，將一個高層次的 cargo build 指令轉化為數千個精確定義的 Job，並利用先進的快取策略最小化重複工作 1。本報告將依序探討 Cargo 的構建單元模型、執行環境的演進（從 Context 到 BuildRunner）、任務隊列的並發控制、以及其核心競爭力所在——基於雜湊與依賴檔案的指紋快取機制。

## **2\. 構建的原子理論：Unit 結構體與單元圖譜**

在 Cargo 的內部視角中，構建過程並非線性的腳本執行，而是一個圖論問題的求解過程。理解 Cargo 如何將抽象的套件定義轉化為具體的編譯任務，首先必須理解其最基本的原子結構——Unit。

### **2.1 Unit 結構體的深度定義**

Unit 結構體在 cargo::core::compiler::unit 模組中被定義，它是 Cargo 構建圖中的節點，代表了構建過程中最小的、不可分割的工作單元。一個常見的誤解是認為一個 Package（套件）對應一個編譯任務。事實上，一個 Package 根據其包含的目標（Targets）和編譯設定，可能會分裂成多個不同的 Unit。  
根據 Cargo 的原始碼定義，Unit 結構封裝了執行一次編譯器調用（rustc invocation）所需的所有上下文資訊。這是一個極為關鍵的設計，因為它將「做什麼（What）」與「怎麼做（How）」完全封裝在一個結構體中，使得後續的任務調度器無需關心具體的業務邏輯，只需負責執行。  
Unit 的核心組成欄位如下表所示：

| 欄位名稱 | 類型 | 描述與架構意義 |
| :---- | :---- | :---- |
| pkg | &'a Package | 指向該單元所屬的原始套件物件。包含 Cargo.toml 中定義的所有靜態元數據，如名稱、版本、依賴列表、作者資訊等。這是 Unit 的身份來源。 |
| target | &'a Target | 描述此單元具體要構建的產物類型。這區分了 Library (lib)、Binary (bin)、Test (test)、Benchmark (bench) 或 Custom Build Script (build.rs)。同一套件中的 lib 和 bin 是不同的 Unit。 |
| profile | Profile | 定義編譯器的參數配置集。決定了構建是 debug 還是 release，優化等級 (opt-level)，除錯資訊 (debuginfo)，以及是否啟用 LTO。不同的 Profile 會生成完全不同的二進制代碼，因此必須視為不同的 Unit。 |
| kind | Kind | 區分構建的目標架構是「宿主（Host）」還是「目標（Target）」。在交叉編譯場景中，build.rs 必須在 Host 架構運行，而最終程式在 Target 架構運行，兩者互不干擾。 |
| mode | CompileMode | 指示編譯的意圖模式，如 Build、Test、Doc、Check 或 RunCustomBuild。這影響 Cargo 傳遞給 rustc 的標誌（例如 cargo check 僅生成 Metadata 而不生成代碼）。 |
| features | Vec\<InternedString\> | 該單元啟用的 Feature 列表。由於 Rust 的 Feature 具有加法特性，不同依賴路徑可能激活不同的 Feature 集合，這直接影響編譯產物的雜湊值。 |

這種結構設計體現了 Cargo 對於「構建隔離」的重視。例如，一個專案可能依賴 serde 庫，而該專案的 build.rs 也依賴 serde。在這種情況下，Cargo 會生成兩個獨立的 Unit：一個 kind 為 Target，用於最終程式；一個 kind 為 Host，用於構建腳本。儘管它們指向同一個 Package (pkg)，但由於 kind 不同，它們被視為兩個完全獨立的節點，擁有不同的雜湊值（Hash）和快取路徑，確保了交叉編譯時的正確性 3。

### **2.2 Unit Graph 的生成邏輯**

構建過程的起點是依賴解析（Dependency Resolution）。Cargo 的解析器會讀取根目錄的 Cargo.toml，解析版本約束，生成一個 Resolve 圖，確定每個依賴的確切版本。然而，Resolve 圖僅描述了套件之間的版本依賴關係，並不足以指導構建。Cargo 必須將其進一步轉化為「單元圖（Unit Graph）」。  
Unit Graph 是一個有向圖（Directed Graph），其中節點是 Unit，邊（Edge）代表了編譯時的依賴關係。這個轉換過程發生在 cargo::core::compiler::unit\_graph 模組中，是一個極為複雜的邏輯過程，主要原因在於 Feature 的傳播與目標平台的過濾。  
在生成 Unit Graph 時，Cargo 必須遍歷 Resolve 圖，並為每個需要的操作（如構建依賴庫、運行構建腳本）實例化 Unit。此時，Cargo 會處理 Feature 的聯集邏輯：如果圖中多個依賴路徑啟用了同一個套件的不同 Feature，該套件最終生成的 Unit 將包含這些 Feature 的總和。這一機制雖然強大，但也增加了圖構建的計算成本。  
此外，Unit Graph 還必須處理「循環依賴」的問題。雖然 Rust 禁止庫之間的循環依賴，但 test 目標可以依賴 lib 目標，而 lib 可能依賴其他開發依賴。Cargo 通過將 test 視為依賴 lib 的獨立 Unit 來打破潛在的循環，確保圖是有向無環的（DAG），從而使得拓撲排序和並行執行成為可能 4。

## **3\. 構建指揮中樞：從 Context 到 BuildRunner 的演進**

Cargo 的原始碼架構並非一成不變，隨著 Rust 語言的發展，其內部架構經歷了顯著的重構。理解這一演進對於深入掌握 Cargo 的執行流程至關重要。長期以來，Context 結構體扮演著全域狀態管理者的角色，但在現代架構中，執行職責已逐漸轉移至 BuildRunner。

### **3.1 Context 的歷史地位與職責重構**

在早期的 Cargo 源碼中（以及許多過時的技術文檔中），Context (cargo::core::compiler::context) 是絕對的核心 5。它是一個典型的「上帝物件（God Object）」，幾乎囊括了構建生命週期中的所有資訊：

* **已解析的套件圖譜** (Resolve)。  
* **編譯配置** (BuildConfig)，包含並行數、目標架構等。  
* **單元圖** (UnitGraph)。  
* **編譯產物追蹤**：記錄哪些檔案已生成，哪些動態庫需要鏈接。  
* **環境資訊**：如 rustc 的版本資訊、宿主機的系統資訊。

然而，隨著功能的堆疊，Context 變得過於臃腫且職責邊界模糊。為了提高代碼的可維護性並支持更複雜的流水線編譯，Cargo 團隊對其進行了拆解。雖然 Context 的概念在邏輯上依然存在（代表編譯上下文），但其實際的執行邏輯和狀態管理已被重構並遷移至 BuildRunner (cargo::core::compiler::build\_runner) 7。現在，Context 更多地被用作一個靜態的資料容器（常被稱為 BuildContext），負責在構建初期收集不可變的配置資訊，而動態的執行狀態則由 BuildRunner 維護。

### **3.2 BuildRunner 的生命週期與執行流**

現代 Cargo 的一次構建流程 (cargo::ops::cargo\_compile) 可以被劃分為清晰的階段，由 BuildRunner 進行協調 9：

1. 初始化與配置解析 (Configuration Phase)：  
   Cargo 首先加載全域配置（\~/.cargo/config）和專案配置，解析命令行參數。此階段確定了構建的根基，如是否為 \--release 模式，目標平台為何 11。  
2. 上下文建立 (Context Creation)：  
   Cargo 實例化 BuildContext。這涉及到調用 rustc \--print cfg 來獲取編譯器的詳細資訊 (TargetInfo)，這對於處理條件編譯 (cfg) 至關重要。同時，依賴解析器運行，生成 Resolve 圖。  
3. 單元圖構建 (Unit Graph Construction)：  
   基於 Resolve 圖和 BuildContext，Cargo 生成完整的 UnitGraph。這是構建計畫的藍圖。  
4. 執行者初始化 (BuildRunner Initialization)：  
   使用 BuildContext 和 UnitGraph 初始化 BuildRunner。在此階段，Cargo 會準備檔案系統的佈局 (Layout)，確保 target 目錄結構正確，並初始化負責並發控制的 JobQueue 9。  
5. 隊列執行 (Execution Phase \- Drain the Queue)：  
   這是構建的實質執行階段。BuildRunner 將 UnitGraph 轉化為一系列待執行的 Job。它會遍歷圖中的節點，對於每個 Unit，計算其指紋（Fingerprint）以判斷是否需要重編譯。如果需要，則生成一個 Job 並推入 JobQueue。BuildRunner 透過調用 drain\_the\_queue 方法，驅動任務的並行執行，直到所有任務完成或發生錯誤 9。

### **3.3 編譯環境的隔離策略**

BuildRunner 的一個關鍵職責是管理編譯產物的隔離。Rust 支援多 Profile、多 Target 的混合構建，這要求 Cargo 必須精確地隔離不同配置下的產物，以避免快取污染或鏈接錯誤。  
Cargo 使用 Metadata 雜湊來實現這一點。每個 Unit 都會根據其配置計算出一個唯一的 Metadata Hash。例如，serde v1.0.0 在 debug 模式下和 release 模式下，雖然源碼相同，但 Metadata Hash 不同。Cargo 會將這些 Hash 附加在輸出檔名中（如 libserde-a1b2c3d4.rlib），或者將其放置在不同的子目錄中。這種機制確保了即使在同一個 target 目錄下，不同配置的構建產物也能共存，切換 Profile 時無需執行 cargo clean，極大地提升了開發體驗 3。  
此外，BuildRunner 還需處理檔案鎖定（File Locking）。由於多個 cargo 進程可能同時操作同一個 target 目錄（例如一個在運行 IDE 檢查，一個在運行測試），Cargo 使用檔案鎖來同步對共享資源（如依賴資料庫、指紋目錄）的訪問，防止數據損壞 12。

## **4\. 並行執行的心臟：JobQueue 與任務調度**

Cargo 的高效能很大程度上歸功於其積極的並行執行策略。JobQueue (cargo::core::compiler::job\_queue) 是負責管理這些並發任務的核心元件，它實現了一個基於依賴圖的動態調度器。

### **4.1 JobQueue 的依賴驅動調度模型**

JobQueue 維護了一個待執行任務的池。與簡單的先進先出（FIFO）隊列不同，這個隊列的填充和消耗是動態且依賴驅動的。

1. **拓撲排序與就緒狀態**：在構建開始時，只有那些沒有依賴（或依賴已存在）的葉子節點 Unit 會被轉化為 Job 並加入「就緒（Ready）」隊列。  
2. **任務執行與依賴解鎖**：當一個 Job 完成時，JobQueue 會收到通知。它會檢查該 Job 對應的 Unit 是哪些後續 Unit 的依賴。如果某個後續 Unit 的所有依賴都已完成，該 Unit 就會被標記為就緒，其對應的 Job 隨即被創建並加入隊列。  
3. **Token Bucket 並發控制**：為了避免過度並發導致系統崩潰，Cargo 採用了 Token Bucket（令牌桶）機制。使用者透過 \-j 參數設定最大並行數（預設為 CPU 核心數）。每個 Job 在啟動實際的 rustc 進程前，必須從全域的 JobToken 池中獲取一個令牌。這不僅限制了 Cargo 自身的並發，還通過 make 的 JobServer 協議與 build.rs 中調用的 cc 編譯器共享這些令牌，實現了跨工具的全局並發控制 13。

### **4.2 JobState 與跨線程通訊架構**

Cargo 的執行模型是多線程的：主線程負責調度邏輯，而實際的編譯命令通常在工作線程或子進程中執行。JobState (cargo::core::compiler::job\_queue::JobState) 結構體是連接這兩個世界的橋樑 13。

* **訊息通道 (Channel)**：每個 Job 都持有一個發送端，用於將執行過程中的標準輸出（stdout）、標準錯誤（stderr）以及結構化的 JSON 診斷訊息發送回主線程。這確保了即使多個編譯器同時運行，終端輸出的訊息也不會混亂交錯 15。  
* **協調與同步**：JobState 還負責處理任務的取消。如果某個關鍵依賴編譯失敗，主線程會通過共享狀態通知所有正在運行的 Job 終止執行，並清空隊列，實現「快速失敗（Fail Fast）」13。

### **4.3 髒狀態傳播與執行決策**

雖然 Fingerprint 機制在構建初期決定了哪些 Unit *理論上* 需要重編譯，但在 JobQueue 的執行過程中，還存在動態的「髒狀態傳播」。  
如果一個 Unit 被判定為需要重編譯（Dirty），那麼所有依賴於它的 Unit，即使其源碼未變，通常也需要重新鏈接（Relink）。JobQueue 必須動態地傳遞這種 Dirty 標記。在流水線編譯（Pipelined Compilation）場景下，這種邏輯更為微妙：如果上游依賴只改變了函數體而未改變介面（Metadata 不變），下游依賴可能無需重新編譯，只需重新鏈接。JobQueue 負責處理這些複雜的條件判斷 2。

## **5\. 快取的奧義：Fingerprint 指紋機制深度解析**

Cargo 能夠在毫秒級完成「無變更」構建檢查，其祕密在於一套高效且細粒度的指紋（Fingerprint）系統。該系統位於 cargo::core::compiler::fingerprint 模組，是 Cargo 快取邏輯的核心 16。

### **5.1 Fingerprint 的多維度構成**

一個 Unit 的 Fingerprint 並非單一的檔案雜湊，而是一個聚合了多種狀態資訊的複合雜湊值。Fingerprint 結構體包含以下關鍵欄位，任何一個欄位的變化都會導致指紋改變，進而觸發重編譯 18：

* **rustc (u64)**: 編譯器的版本標識（通常是 Commit Hash）。這確保了當使用者升級 Rust 版本後，所有舊的快取自動失效，強制全量重編譯，避免 ABI 不兼容問題。  
* **features (String)**: 該單元啟用的 Feature 列表（排序後）。Feature 的增減會改變代碼的條件編譯路徑，必須視為變更。  
* **target (u64)**: 目標架構配置的雜湊，包括 Target Triple 和 .cargo/config 中的相關設定。  
* **profile (u64)**: 編譯選項的雜湊，涵蓋 opt-level、debuginfo 等。  
* **path (u64)**: 套件根目錄的路徑雜湊。這對於 Path Dependencies 尤為重要。  
* **deps (Vec\<DepFingerprint\>)**: 所有依賴單元的指紋列表。這是一個遞歸定義，構建了一種類似 Merkle Tree 的結構。底層依賴的任何微小變動，都會通過這個列表向上層傳播，導致上層指紋變化，實現級聯的重編譯檢測 16。  
* **local (Mutex\<Vec\<LocalFingerprint\>\>)**: 本地檔案狀態的雜湊。這是最複雜且動態的部分，包含原始碼檔案的 mtime 或內容雜湊，以及 build.rs 動態注入的依賴資訊。

### **5.2 檔案系統中的指紋儲存**

Cargo 將計算出的指紋持久化儲存在 target/debug/.fingerprint/（或 target/release/.fingerprint/）目錄下。每個 Unit 都有一個對應的目錄，其中包含關鍵的狀態檔案 17：

1. **雜湊檔案**：檔名即為 16 進制的雜湊值（例如 target/debug/.fingerprint/pkg-name-a1b2/output-lib-pkg）。Cargo 啟動時只需計算當前狀態的雜湊並檢查該檔案是否存在，即可快速判斷 Fresh/Dirty。  
2. **.json 檔案**：這是一個包含詳細指紋資訊的 JSON 檔案。它主要用於除錯和日誌記錄。當開發者使用 CARGO\_LOG=cargo::core::compiler::fingerprint=trace 進行排查時，Cargo 會讀取此檔案以解釋為什麼發生了重編譯（例如「Feature X changed」）19。  
3. **invoked.timestamp**：記錄構建開始的時間戳。這用於處理「構建過程中檔案被修改」的競態條件。如果源碼檔案的 mtime 晚於這個時間戳，說明在構建時檔案又變了，下次構建時必須視為 Dirty 17。

### **5.3 DirtyReason：精確的變更診斷**

當 Cargo 判定一個 Unit 需要重編譯時，它會生成一個 DirtyReason 枚舉值。這不僅是內部邏輯的依據，也是提供給使用者的診斷資訊。主要的 DirtyReason 類型包括 20：

* **FreshBuild / NothingObvious**: 指紋檔案不存在，通常是第一次構建或被 clean 清除。  
* **FeaturesChanged**: Cargo.toml 中的 features 設定發生變化。  
* **TargetConfigurationChanged**: 目標平台或 rustflags 改變。  
* **PathToSourceChanged**: 這是最常見的原因，意味著源碼檔案被修改。Cargo 通過比對 dep-info 檔案中記錄的源碼路徑與檔案系統的 mtime 來發現這一點。  
* **UnitDependencyInfoChanged**: 上游依賴的指紋發生了變化。

### **5.4 Checksum Freshness：超越 mtime 的嘗試**

傳統上，Cargo 依賴檔案系統的 mtime（修改時間）來檢測源碼變更。這雖然快速，但存在缺陷：例如，使用 git checkout 切換分支時，檔案的 mtime 會更新，即使內容可能與上次構建時相同，這會導致不必要的重編譯。  
為了精確控制，Rust 引入了不穩定的 checksum-freshness 功能。啟用此功能後，Cargo 會在指紋中儲存每個源碼檔案的內容校驗和（Checksum，通常是 SHA-256）。在檢查時，Cargo 會讀取檔案內容並重新計算雜湊進行比對。雖然這增加了 I/O 和 CPU 開銷，但在頻繁切換分支或使用分佈式檔案系統的場景下，能顯著減少重編譯次數 16。

## **6\. 精確依賴追蹤：dep-info 的生成與解析**

Cargo 如何得知一個 lib.rs 具體引用了哪些 mod.rs 檔案？它並不會自己去解析 Rust 語法，而是依賴編譯器 rustc 的協助。dep-info 機制是連接編譯器知識與構建系統快取的橋樑。

### **6.1 rustc 的 \--emit=dep-info 機制**

每當 Cargo 調用 rustc 編譯一個單元時，它都會傳遞 \--emit=dep-info 參數 17。這指示 rustc 在進行語法解析和模組加載的過程中，記錄下所有被讀取過的源碼檔案路徑。編譯完成後，rustc 會生成一個以 .d 結尾的依賴資訊檔。  
這個 .d 檔案的格式遵循 Makefile 的語法規範：

Makefile

/path/to/target/debug/deps/libfoo.rlib: /src/lib.rs /src/foo/mod.rs /src/bar.rs...

這行描述清晰地告訴 Cargo：要生成 libfoo.rlib，必須依賴後面列出的所有源碼檔案 17。

### **6.2 Cargo 的解析與轉換 (parse\_dep\_info)**

Cargo 並不會直接將 rustc 生成的 .d 檔案用於快取檢查，因為這些檔案通常包含絕對路徑，且文字格式解析較慢。Cargo 的 cargo::core::compiler::fingerprint::dep\_info 模組包含了一個專門的解析器 parse\_dep\_info 16。  
該解析器執行以下關鍵操作：

1. **路徑規範化**：將絕對路徑轉換為相對於專案根目錄的相對路徑，以提高快取的可移植性。  
2. **環境變數提取**：rustc 會將編譯過程中使用的環境變數（如 env\!("CARGO\_PKG\_VERSION")）以特殊註釋 \# env-var:KEY=VALUE 的形式寫入 .d 檔案。Cargo 解析這些註釋，並將其加入 Fingerprint 的 local 部分。這樣，如果該環境變數在下次構建時發生變化，Cargo 也能檢測到並觸發重編譯，即使源碼檔案沒有變動 17。  
3. **格式轉換**：解析後的資訊被轉換為 Cargo 內部的高效格式，儲存在 .fingerprint 目錄下的二進制或優化後的 dep-info 檔案中。

### **6.3 二進制依賴與 \-Z binary-dep-depinfo**

在標準的 dep-info 中，通常只包含源碼檔案。然而，在某些特殊場景下，例如構建 Rust 編譯器自身（Bootstrapping）或使用預編譯的二進制庫時，構建過程可能依賴於其他的二進制產物（如 .rlib 或 .so）。  
為了處理這種情況，Cargo 引入了 \-Z binary-dep-depinfo 標誌。啟用後，dep-info 檔案將包含二進制依賴的路徑。這使得 Cargo 能夠像追蹤源碼一樣追蹤二進制庫的變化，實現更嚴格的增量構建一致性 23。

## **7\. 流水線編譯 (Pipelined Compilation) 與效能優化**

隨著 Rust 專案規模的增長，編譯時間成為了主要痛點。Cargo 引入了「流水線編譯（Pipelined Compilation）」技術，這是一項利用 Rust 編譯器特性來最大化構建並行度的架構創新。

### **7.1 Metadata 與 Codegen 的分離**

Rust 的編譯流程可以邏輯上分為前端（Frontend）和後端（Backend）：

1. **前端分析**：包括語法解析、宏展開、名稱解析、類型檢查和借用檢查。這一階段產出的結果被稱為「元數據（Metadata）」，通常儲存為 .rmeta 檔案。  
2. **後端生成**：包括 LLVM IR 的生成、優化（Optimization）和機器碼生成（Codegen），最終產生 .rlib 或執行檔。這是最耗時的階段。

在傳統的「瀑布式」構建中，如果套件 B 依賴套件 A，B 必須等待 A 完成所有階段（包括耗時的後端生成）才能開始編譯。但實際上，B 的前端分析只需要 A 的 Metadata（類型定義、泛型簽名）即可進行，無需等待 A 的機器碼生成。

### **7.2 Cargo 的流水線調度策略**

啟用 Pipelining 後（現為預設啟用），Cargo 調整了其與 rustc 的交互方式 2：

1. **信號機制**：Cargo 指示 rustc 在完成前端分析並生成 .rmeta 檔案後，立即發送一個信號（通常是通過關閉一個特定的文件描述符或創建一個標記檔案）。  
2. **提早啟動**：JobQueue 監聽到套件 A 的 Metadata 就緒信號後，會立即啟動套件 B 的編譯任務。此時，套件 A 的 rustc 進程仍在後台繼續進行代碼生成。  
3. **並行重疊**：這使得套件 B 的前端分析與套件 A 的後端生成在時間上重疊（Overlap）。在多核 CPU 上，這顯著提高了資源利用率。

數據顯示，Pipelining 可以將某些依賴鏈較長的專案的構建時間縮短 10-20% 2。然而，這也增加了 JobQueue 調度邏輯的複雜度，因為 Cargo 現在必須區分「Metadata 就緒」和「Artifact 就緒」兩種不同的完成狀態，並正確處理編譯失敗時的狀態清理。

## **8\. 構建腳本 (build.rs) 的整合挑戰**

build.rs 是 Rust 生態系統中極具彈性但也最為複雜的功能之一。它允許在編譯主要代碼之前執行任意的 Rust 代碼，用於生成代碼（如 Protobuf）、編譯 C 依賴或檢測系統環境。這對 Cargo 的依賴圖和快取機制提出了特殊挑戰。

### **8.1 宿主與目標架構的雙重世界**

如 Unit 結構所述，build.rs 必須在「宿主（Host）」架構上編譯和運行，以便在當前機器上執行；而它生成的配置或代碼則服務於「目標（Target）」架構的構建。這導致 Cargo 在構建圖中必須維護兩套平行的依賴樹。例如，一個專案交叉編譯到 Android，其 build.rs 使用的 cc crate 是 x86\_64 版本的（Host），而主程式使用的 libc 是 ARM 版本的（Target）。Unit 的 kind 欄位正是為了區分這一點 3。

### **8.2 動態依賴注入與 rerun-if**

build.rs 通過標準輸出（stdout）與 Cargo 通訊。這是一種動態協議，允許腳本在運行時改變構建行為：

* **cargo:rustc-link-lib=...**: 動態指示 Cargo 鏈接外部庫。  
* **cargo:rerun-if-changed=PATH**: 這是增量編譯的關鍵。它告訴 Cargo：「除了靜態源碼外，還請監視 PATH 這個檔案（可能是 C header、配置檔等）」。

Cargo 必須捕獲並解析這些輸出。這些動態生成的依賴會被合併到該 Unit 的 Fingerprint 中（local 欄位）。下次構建時，Cargo 不僅檢查 dep-info 中的源碼，還會檢查 rerun-if-changed 指定的檔案。  
如果 build.rs 沒有輸出任何 rerun-if 指令，Cargo 會採取保守的「悲觀策略」：只要該套件目錄下的 *任何* 檔案發生變化，就假設需要重新運行 build.rs。這往往是導致大型專案過度重編譯的元兇。因此，Cargo 的最佳實踐強烈建議 build.rs 明確輸出所有依賴 17。

## **9\. 結論與未來展望**

Cargo 的源碼架構展現了一個現代化構建系統如何在正確性、靈活性與效能之間尋求平衡。透過將構建過程原子化為 Unit，Cargo 獲得了極高的調度靈活性，能夠輕鬆應對交叉編譯與多 Profile 構建；透過基於雜湊、特徵與時間戳混合的 Fingerprint 機制，它實現了高效且可靠的增量編譯檢測；而 dep-info 與 build.rs 協議的整合，則確保了即使在面對動態代碼生成與外部 C 依賴時，依賴追蹤依然精確無誤。  
從架構演進的角度來看，從單一的 Context 到職責分離的 BuildRunner，以及流水線編譯（Pipelining）的引入，顯示了 Cargo 團隊在持續優化核心引擎以適應大規模單體倉庫（Monorepo）的需求。  
展望未來，Cargo 的架構仍有幾個重要的演進方向：

1. **Checksum Freshness 的穩定化**：擺脫對檔案系統時間戳的依賴，實現更純粹的基於內容的快取。  
2. **共享快取 (Shared Caching) 的原生整合**：目前像 sccache 這樣的工具是作為 wrapper 存在的。Cargo 內部架構的演進（如 Unit 雜湊的標準化）正為原生支援分佈式或本地共享快取鋪平道路，這將徹底改變 CI/CD 環境下的構建效率 3。  
3. **Metabuild**：一種更宣告式的 build.rs 替代方案，旨在減少動態腳本帶來的快取不確定性 23。

對於深入研究 Rust 工具鏈的開發者而言，理解這些內部機制不僅有助於編寫更高效的 build.rs 和配置 Cargo.toml，更是參與 Rust 編譯器與構建工具貢獻的必要前提。Cargo 的代碼庫本身也是 Rust 系統程式設計的一個典範，展示了如何用 Rust 構建一個並行、安全且強健的複雜系統。

### ---

**附錄：關鍵資料結構與模組對照表**

為方便開發者對照原始碼閱讀，以下列出本報告提及的關鍵結構與其在 Cargo 源碼樹中的位置。

| 結構體/概念 | 主要職責 | 關鍵欄位/方法 | 對應原始碼模組 |
| :---- | :---- | :---- | :---- |
| **Unit** | 最小編譯單元，構建圖的節點 | pkg, target, profile, kind, mode | cargo::core::compiler::unit |
| **UnitGraph** | 描述所有單元及其依賴的有向圖 | HashMap\<Unit, Vec\<UnitDep\>\> | cargo::core::compiler::unit\_graph |
| **BuildRunner** | 構建過程的執行者，狀態持有者 | bcx, job\_queue, layout, drain\_the\_queue() | cargo::core::compiler::build\_runner |
| **Context** | (舊/輔助) 編譯上下文 | resolve, packages, config | cargo::core::compiler::context |
| **JobQueue** | 並行任務調度器 | queue, tokens, active | cargo::core::compiler::job\_queue |
| **Fingerprint** | 快取狀態的快照 | rustc, deps, local, memoized\_hash | cargo::core::compiler::fingerprint |
| **DirtyReason** | 記錄重編譯原因 | RustcChanged, PathToSourceChanged | cargo::core::compiler::fingerprint::dirty\_reason |
| **dep-info** | 依賴資訊解析器 | parse\_dep\_info() | cargo::core::compiler::fingerprint::dep\_info |

#### **引用的著作**

1. Rust's incremental compiler architecture \- LWN.net, 檢索日期：12月 22, 2025， [https://lwn.net/Articles/997784/](https://lwn.net/Articles/997784/)  
2. Evaluating pipelined rustc compilation \- Rust Internals, 檢索日期：12月 22, 2025， [https://internals.rust-lang.org/t/evaluating-pipelined-rustc-compilation/10199](https://internals.rust-lang.org/t/evaluating-pipelined-rustc-compilation/10199)  
3. Make Cargo share dependencies for different projects? \- Rust Users Forum, 檢索日期：12月 22, 2025， [https://users.rust-lang.org/t/make-cargo-share-dependencies-for-different-projects/23112](https://users.rust-lang.org/t/make-cargo-share-dependencies-for-different-projects/23112)  
4. Multiple libraries in a cargo project \- Rust Internals, 檢索日期：12月 22, 2025， [https://internals.rust-lang.org/t/multiple-libraries-in-a-cargo-project/8259](https://internals.rust-lang.org/t/multiple-libraries-in-a-cargo-project/8259)  
5. Cargo is entering an infinite loop · Issue \#7840 · rust-lang/cargo \- GitHub, 檢索日期：12月 22, 2025， [https://github.com/rust-lang/cargo/issues/7840](https://github.com/rust-lang/cargo/issues/7840)  
6. Hey Rustaceans\! Got an easy question? Ask here (31/2019)\! : r/rust \- Reddit, 檢索日期：12月 22, 2025， [https://www.reddit.com/r/rust/comments/cjafjc/hey\_rustaceans\_got\_an\_easy\_question\_ask\_here/](https://www.reddit.com/r/rust/comments/cjafjc/hey_rustaceans_got_an_easy_question_ask_here/)  
7. June 2024 \- openSUSE Commits, 檢索日期：12月 22, 2025， [https://lists.opensuse.org/archives/list/commit@lists.opensuse.org/2024/6/?page=104](https://lists.opensuse.org/archives/list/commit@lists.opensuse.org/2024/6/?page=104)  
8. BuildRunner in cargo::core::compiler::build\_runner \- Rust, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/build\_runner/struct.BuildRunner.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/build_runner/struct.BuildRunner.html)  
9. cargo::ops::cargo\_compile \- Rust, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/nightly/nightly-rustc/cargo/ops/cargo\_compile/index.html](https://doc.rust-lang.org/nightly/nightly-rustc/cargo/ops/cargo_compile/index.html)  
10. os error 2 (no such file or dir) when compiling rust-1.87.0 · Issue \#142622 \- GitHub, 檢索日期：12月 22, 2025， [https://github.com/rust-lang/rust/issues/142622](https://github.com/rust-lang/rust/issues/142622)  
11. Configuration \- The Cargo Book \- Rust Documentation, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/cargo/reference/config.html](https://doc.rust-lang.org/cargo/reference/config.html)  
12. cargo/core/compiler/ layout.rs, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/src/cargo/core/compiler/layout.rs.html](https://doc.rust-lang.org/beta/nightly-rustc/src/cargo/core/compiler/layout.rs.html)  
13. "" Search \- Rust, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/src/cargo/core/compiler/job\_queue/job\_state.rs.html?search=](https://doc.rust-lang.org/beta/nightly-rustc/src/cargo/core/compiler/job_queue/job_state.rs.html?search)  
14. meteor-job \- NPM, 檢索日期：12月 22, 2025， [https://www.npmjs.com/package/meteor-job](https://www.npmjs.com/package/meteor-job)  
15. Activating features for tests/benchmarks · Issue \#2911 · rust-lang/cargo \- GitHub, 檢索日期：12月 22, 2025， [https://github.com/rust-lang/cargo/issues/2911](https://github.com/rust-lang/cargo/issues/2911)  
16. cargo/core/compiler/fingerprint/ mod.rs \- Docs.rs, 檢索日期：12月 22, 2025， [https://docs.rs/cargo/latest/src/cargo/core/compiler/fingerprint/mod.rs.html](https://docs.rs/cargo/latest/src/cargo/core/compiler/fingerprint/mod.rs.html)  
17. Module fingerprint \- cargo::core::compiler \- Rust Documentation, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html)  
18. Fingerprint in cargo::core::compiler, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/struct.Fingerprint.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/struct.Fingerprint.html)  
19. Fingerprint of dependency in workspace changes when running \`cargo build\` and \`cargo build \-p  
20. dirty\_reason.rs \- cargo/core/compiler/fingerprint \- Docs.rs, 檢索日期：12月 22, 2025， [https://docs.rs/cargo/latest/src/cargo/core/compiler/fingerprint/dirty\_reason.rs.html](https://docs.rs/cargo/latest/src/cargo/core/compiler/fingerprint/dirty_reason.rs.html)  
21. translate\_dep\_info in cargo::core::compiler::fingerprint::dep\_info \- Rust, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/dep\_info/fn.translate\_dep\_info.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/dep_info/fn.translate_dep_info.html)  
22. RustcDepInfo in cargo::core::compiler::fingerprint::dep\_info \- Rust, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/dep\_info/struct.RustcDepInfo.html](https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/dep_info/struct.RustcDepInfo.html)  
23. Unstable Features \- The Cargo Book \- Rust Documentation, 檢索日期：12月 22, 2025， [https://doc.rust-lang.org/cargo/reference/unstable.html](https://doc.rust-lang.org/cargo/reference/unstable.html)  
24. Reducing Cargo target directory size with \-Zno-embed-metadata | Kobzol's blog, 檢索日期：12月 22, 2025， [https://kobzol.github.io/rust/rustc/2025/06/02/reduce-cargo-target-dir-size-with-z-no-embed-metadata.html](https://kobzol.github.io/rust/rustc/2025/06/02/reduce-cargo-target-dir-size-with-z-no-embed-metadata.html)  
25. How to speed up the Rust compiler one last time – Nicholas Nethercote \- The Mozilla Blog, 檢索日期：12月 22, 2025， [https://blog.mozilla.org/nnethercote/2020/09/08/how-to-speed-up-the-rust-compiler-one-last-time/](https://blog.mozilla.org/nnethercote/2020/09/08/how-to-speed-up-the-rust-compiler-one-last-time/)  
26. src/tools/cargo/tests/testsuite/build\_script.rs \- toolchain/rustc \- Git at Google, 檢索日期：12月 22, 2025， [https://android.googlesource.com/toolchain/rustc/+/HEAD/src/tools/cargo/tests/testsuite/build\_script.rs](https://android.googlesource.com/toolchain/rustc/+/HEAD/src/tools/cargo/tests/testsuite/build_script.rs)  
27. \--emit=dep-info or some flag should include rlibs & externally linked files that will be used · Issue \#57717 · rust-lang/rust \- GitHub, 檢索日期：12月 22, 2025， [https://github.com/rust-lang/rust/issues/57717](https://github.com/rust-lang/rust/issues/57717)