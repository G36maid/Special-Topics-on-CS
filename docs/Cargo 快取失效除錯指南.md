# **Cargo 建置快取失效鑑識分析報告：從時光倒流術失效看指紋識別機制的深層病理**

## **摘要**

本報告針對 Cargo 建置系統中出現的非預期重編譯（Spurious Rebuild）現象進行深入的鑑識分析。特別針對使用者嘗試透過操作檔案系統時間戳記（即 find. \-exec touch...，俗稱「時光倒流術」）來規避重編譯卻失效的場景。此現象不僅是單純的工具失靈，更是一個關鍵的診斷訊號，表明 Cargo 的快取無效化邏輯已經跨越了第一層的「時間戳記啟發式檢查（Mtime Heuristic）」，進入了更深層且嚴格的「內容指紋比對（Content Fingerprinting）」階段。  
本報告將長達 25 頁的篇幅，詳盡解構 Cargo 內部指紋機制的運作原理，並針對使用者提出的四個核心假設——絕對路徑污染、build.rs 隱形依賴、RUSTFLAGS 組態差異、以及檔案系統 Mtime 精度問題——進行病理學式的剖析。我們將揭示為何在看似相同的原始碼環境下，Cargo 仍判定單元為「不新鮮（Dirty）」，並提供一套系統化的鑑識調查計畫，協助工程團隊在 CI/CD 管道、Docker 容器化環境以及複雜的工作區（Workspace）配置中，實現真正的確定性建置（Deterministic Builds）。

## **1\. Cargo 快取與指紋識別機制之解剖**

要理解為何「時光倒流術」會失效，首先必須建立對 Cargo 判斷「新鮮度（Freshness）」的完整認知模型。Cargo 並非單純依賴 Make 風格的時間戳記比對，而是採用了一套混合式的雙層檢查機制。當使用者執行 cargo build 時，系統會依序進行以下判斷，任何一個環節的「不匹配」都會導致編譯單元（Compilation Unit）被標記為 Dirty，進而觸發 rustc 的調用。

### **1.1 雙層新鮮度模型：從啟發式到決定論**

Cargo 的決策樹可以分為兩個主要層次：淺層的檔案系統檢查與深層的指紋雜湊比對。

#### **第一層：檔案系統時間戳記（Mtime Check）**

這是最傳統的檢查方式，也是 touch 指令試圖欺騙的對象。Cargo 會檢查原始碼檔案（Source Files）的修改時間（mtime）是否晚於目標產物（Artifacts）的時間。

* **機制**：Cargo 讀取 target/debug/.fingerprint/\<crate\>/ 下的 dep-lib-\<crate\> 檔案（其中包含該 crate 依賴的所有原始檔列表），並比較這些檔案的 mtime 與 invoked.timestamp 檔案的 mtime 。  
* **失效意義**：如果使用者已經使用 touch 將所有原始碼的時間設為舊時間，或者與上次編譯時間一致，理論上這一層檢查應該通過。然而，如果 Cargo 仍然執行重編譯，這意味著 Cargo **並未** 在這一層停下，或者 Cargo 發現了除了「原始碼時間」以外的變因。這正是本報告的核心：當 Mtime 檢查失效時，決策權就移交給了第二層。

#### **第二層：指紋雜湊比對（Fingerprint Hash Check）**

這是 Cargo 確保建置正確性的最後防線。Cargo 會將當前的編譯環境狀態計算出一個 64 位元的雜湊值（Fingerprint Hash），並與上一次成功編譯時儲存在磁碟上的雜湊值進行比對。

* **儲存位置**：target/debug/.fingerprint/\<crate\>-\<hash\>/\<hash\> 。  
* **不可欺騙性**：這個雜湊值包含了大量與檔案時間戳記無關的資訊。如果編譯器參數改變、環境變數改變、或者依賴圖譜發生微小變動，即便原始碼檔案的 mtime 是一百年前，雜湊值也會不同，從而強制重編譯。

### **1.2 指紋結構體（Fingerprint Struct）的微觀分析**

根據 Cargo 的原始碼與內部文件 ，一個 Fingerprint 結構體並非單一數值，而是由多個欄位複合而成的狀態快照。任何一個欄位的變動都會導致整體的 Dirty。

| 欄位名稱 (Field) | 內容描述 (Description) | 鑑識相關性 (Forensic Relevance) |
| :---- | :---- | :---- |
| rustc | rustc 編譯器的版本雜湊。 | 若 CI 升級了 Rust 版本，所有快取立即失效。 |
| features | 啟用的 Cargo Features 排序列表。 | 隱式的 Feature 啟用（由其他 Crate 觸發）常導致此欄位變動。 |
| target | 目標架構（Target Triple）的雜湊。 | 交叉編譯或 Target JSON 的微小差異會觸發重編譯。 |
| profile | 編譯設定檔（Profile）的雜湊（如 debug/release, lto, panic 策略）。 | 切換 Profile 或修改 RUSTFLAGS 會直接改變此雜湊。 |
| **path** | **基礎原始碼檔案的路徑雜湊。** | **高度嫌疑。** 絕對路徑的變動會改變此值。 |
| deps | 所有上游依賴項（Dependencies）的指紋列表。 | 依賴項的 Dirty 狀態會向上傳播。 |
| **local** | **本地輸入變因（如 build.rs 監聽的環境變數）。** | **高度嫌疑。** 環境變數的波動是隱形殺手。 |
| memoized\_hash | 快取的最終雜湊值。 | 用於快速比對。 |

當「時光倒流術」失效時，極大機率是 path、local 或 profile 這三個欄位中的某一個發生了變動。這些變動是「內容性」或「組態性」的，而非「時間性」的。

### **1.3 dep-info 檔案與依賴追蹤**

除了指紋雜湊，Cargo 還依賴 rustc 生成的 .d 檔案（Dependency Info）。這些檔案採用類似 Makefile 的語法，列出了產出一個 Artifact 所需的所有輸入檔案。

* **絕對路徑預設**：預設情況下，.d 檔案內使用的是絕對路徑 。  
* **檢核邏輯**：Cargo 在建置前會解析 .d 檔案，檢查列出的每一個檔案是否存在。如果專案目錄被移動（例如在 Docker 構建中，從 /app/v1 移動到 /app/v2），Cargo 會發現舊的 .d 檔案指向的路徑不存在，因此判定依賴資訊無效（Stale），強制重編譯以生成正確的依賴關係 。這是一個常見的「假性 Dirty」來源，即便檔案內容完全一致，路徑的改變也會導致快取失效。

## **2\. 假設一：絕對路徑污染（Absolute Path Pollution）的病理分析**

在現代化的建置環境中，特別是分散式快取（如 sccache）或容器化 CI/CD 流程中，絕對路徑污染是導致快取命中率低落與非預期重編譯的首要嫌疑犯。

### **2.1 絕對路徑的嵌入機制**

Rust 編譯器 rustc 與 Cargo 在設計上傾向於使用絕對路徑來消除歧義，這在單機開發環境中是合理的，但在需要「可移植性（Portability）」的場景下則成為災難。

1. **除錯資訊（Debug Info / DWARF）**： 為了讓除錯器（如 gdb 或 lldb）能夠找到原始碼進行單步執行，rustc 預設會將編譯時的絕對路徑嵌入到二進位檔（.rlib,.rmeta,.so, executable）的 DWARF 區段中 。這意味著，如果在 /home/alice/project 編譯，二進位檔內就會包含 /home/alice/... 字串。如果在 /home/bob/project 編譯，字串則不同。對於 Cargo 的指紋機制來說，這代表產出物的內容發生了變化。  
2. **Panic 訊息與 file\!() 巨集**： std::panic\! 以及 file\!() 巨集會展開為呼叫處的檔案路徑。這些路徑通常是絕對路徑，直接烙印在程式碼的 .rodata 區段中 。這導致了即便程式邏輯沒變，只要專案根目錄改變，編譯出的 Hash 就會不同。  
3. **指紋雜湊中的 path 欄位**： 如前所述，Cargo 的 Fingerprint 結構體中有一個 path 欄位，專門用來雜湊「套件根目錄」或「入口原始檔」的路徑 。對於路徑依賴（Path Dependencies）或工作區成員，這個雜湊值是基於它們在檔案系統中的絕對位置計算的。

### **2.2 工作區（Workspace）與 Git Worktree 的衝突**

使用者若使用 Git Worktree 來管理多個分支，會自然地在不同的目錄下（例如 /work/feature-a 與 /work/feature-b）擁有相同的程式碼。

* **情境**：使用者在 /work/feature-a 建置了一次，然後切換到 /work/feature-b（程式碼完全相同）。  
* **結果**：Cargo 檢查 path 指紋，發現 /work/feature-a\!= /work/feature-b。指紋不匹配，觸發重編譯。  
* **鑑識特徵**：此類重編譯通常是全面的，因為基礎路徑的改變會波及所有子 crate。

### **2.3 Sccache 的雜湊鍵（Hash Key）敏感度**

若專案使用了 sccache 來加速編譯，絕對路徑污染的影響會被放大。sccache 的工作原理是計算編譯器呼叫指令（Command Line Invocation）的雜湊作為快取鍵（Cache Key）。

* **雜湊鍵構成**：Hash(Compiler Binary \+ Arguments \+ Env Vars) 。  
* **污染鏈**：Cargo 傳遞給 rustc 的參數包含絕對路徑（例如 rustc /abs/path/to/main.rs...）。  
* **結果**：目錄改變 \\rightarrow 參數字串改變 \\rightarrow Cache Key 改變 \\rightarrow Cache Miss。這解釋了為什麼即使檔案內容沒變，移到新目錄後 sccache 依然無法命中，導致「實質上」的重編譯 。

### **2.4 緩解策略：路徑重映射（Remapping）**

為了解決此問題，Rust 提供了 \--remap-path-prefix 參數，這在鑑識過程中是一個關鍵的對照組。如果加入此參數後重編譯消失，則證實了絕對路徑污染是主因。

* **原理**：告訴編譯器在生成中間產物與最終產物時，將特定的路徑前綴（如 /home/user/project）替換為一個通用的佔位符（如 /src）。  
* **限制**：這通常需要透過 .cargo/config.toml 或環境變數 RUSTFLAGS 全域設定，且可能會影響 panic 訊息的可讀性（除非除錯器也設定了對應的 sourcemap）。

## **3\. 假設二：build.rs 的隱形依賴與環境波動**

自定義建置腳本（build.rs）是 Rust 建置系統中的「黑盒子」。它們在編譯期執行任意程式碼，並透過標準輸出（stdout）與 Cargo 進行通訊，動態地影響 Cargo 的快取決策。

### **3.1 rerun-if-changed 的路徑陷阱**

build.rs 可以輸出 cargo:rerun-if-changed=PATH 指令，告知 Cargo 監控特定檔案或目錄。

* **絕對路徑問題**：如果 build.rs 計算出一個絕對路徑並輸出（例如透過 fs::canonicalize），這個路徑就會被寫入指紋的 local 欄位。當專案移動時，這個路徑失效或改變，導致指紋不匹配 。  
* **目錄監控**：如果指向的是一個目錄，Cargo 需要掃描整個目錄的 mtime。在某些檔案系統操作下（如 git checkout 或 Docker layer extraction），目錄的 mtime 可能會發生變化，即使內容未變，這也會觸發重編譯 。

### **3.2 rerun-if-env-changed 與環境變數漂移**

這是最常見且最難以察覺的「隱形殺手」。build.rs 可以聲明依賴於特定的環境變數（如 CC, CFLAGS, PKG\_CONFIG\_PATH）。

* **環境雜訊**：在 CI 或 Docker 環境中，基礎映像檔的更新可能會微調環境變數。例如，PATH 變數中可能被插入了動態路徑，或者 LD\_LIBRARY\_PATH 發生了改變。  
* **觸發機制**：Cargo 會記錄建置時這些變數的**確切值**。只要值有任何字串上的差異（哪怕是多了一個空白或順序對調），local 指紋就會改變，強制重編譯 。  
* **案例**：Snippet 顯示了一個具體的 Dirty 原因：Dirty ring v0.17.8: the env variable PATH changed。這證明了環境變數的微小變動足以導致大規模的重編譯。

### **3.3 隱式依賴與「自產生」檔案**

有些 build.rs 會生成原始碼（例如 Protobuf 編譯或 Bindgen），並將其寫入 OUT\_DIR 或甚至原始碼目錄（雖然 Cargo 不建議）。

* **時間戳記循環**：如果 build.rs 每次執行都無條件地寫入檔案（沒有檢查內容是否變更），那麼生成檔案的 mtime 會被更新為「現在」。  
* **連鎖反應**：主程式依賴這個生成檔案。因為生成檔案變「新」了，主程式被判定為 Dirty，觸發重編譯。這是一個「自我毀滅」的快取機制，touch 原始碼完全無效，因為無效化源頭來自建置過程本身 。

## **4\. 假設三：RUSTFLAGS 與組態組（Configuration Profiles）的差異**

Cargo 的指紋不僅包含原始碼狀態，還包含「如何編譯」的組態狀態。Fingerprint 中的 profile 欄位負責捕捉這類變動。

### **4.1 Host 與 Target 的編譯參數分裂**

Cargo 有一個鮮為人知但影響巨大的行為：Host Artifacts（如 build.rs, Proc-Macros）與 Target Artifacts（最終二進位檔）的編譯參數處理方式不同。

* **無 \--target 時**：若使用者執行 cargo build（預設 Host 架構），Cargo 會嘗試在 Host 與 Target 之間共享依賴項（如 syn, quote）。此時，傳遞給 Cargo 的 RUSTFLAGS 會同時應用於兩者 。  
* **有 \--target 時**：若使用者執行 cargo bu\[span\_7\](start\_span)\[span\_7\](end\_span)ild \--target x86\_64-unknown-linux-gnu，Cargo 會嚴格區分 Host 與 Target。Host Artifacts 將**不會**繼承 RUSTFLAGS（除非設定了 target-applies-to-host），而 Target Artifacts 會繼承。  
* **快取失效場景**：如果使用者在本地開發時混用帶 \--target 與不帶 \--target 的指令，或者在 CI 中使用了不同的 flag 組合，共享的依賴項會因為 RUSTFLAGS 的有無而不斷切換指紋，導致反覆重編譯。

### **4.2 Feature Unification 的副作用**

Rust 的 Feature Unification 機制會將依賴樹中所有 crate 啟用的 features 進行聯集。

* **情境**：Crate A 依賴 serde (features \= \["derive"\])，Crate B 依賴 serde (features \= \["rc"\])。在 Workspace 中建置時，serde 會被編譯為 \["derive", "rc"\]。  
* **失效**：如果使用者嘗試單獨建置 Crate A（cargo build \-p crate-a），Cargo 可能會嘗試只用 \["derive"\] 編譯 serde。這會導致 serde 的指紋改變（features 欄位變動）。如果隨後又進行 Workspace 建置，serde 又要重編譯。這種「來回拉鋸」是工作區開發中常見的痛點。

## **5\. 假設四：檔案系統 Mtime 精度與保存問題**

雖然使用者的假設是「時間戳記不是理由」，但在某些極端情況下，時間戳記的「精度」或「保存方式」本身就是指紋不匹配的根源。

### **5.1 奈秒級精度（Nanosecond Precision）的誤差**

現代檔案系統（Ext4, XFS, APFS, Btrfs）都支援奈秒級的時間戳記。

* **比較邏輯**：Cargo 的比較是非常嚴格的。它比較的是 source\_file.mtime 與 invoked.timestamp（建置開始時間）。如果 source\_file.mtime \> invoked.timestamp，則視為 Dirty 。  
* **誤差來源**：  
  * **Docker COPY**：Docker 的 COPY 指令在某些版本或設定下，可能不會完美保留奈秒部分，或者將其截斷（Truncate）為 0。  
  * **Git 操作**：git checkout 更新檔案時，會將 mtime 設為「當前時間」。如果建置過程極快，或者系統時鐘有微小回溯（NTP 同步），可能會出現「檔案時間」微幅晚於「建置開始時間」的情況，導致 Cargo 誤判檔案在建置過程中被修改了。  
  * **跨檔案系統搬運**：從高精度檔案系統（如 APFS）複製到低精度檔案系統（如某些網路掛載或舊版 FAT）時，精度的遺失可能導致比較邏輯出錯。

### **5.2 Btrfs Reflinks 與 Inode 變動**

使用者提到了 Docker 與 Btrfs driver 。Btrfs 支援 Copy-on-Write (CoW) 與 Reflinks。

* **Reflink 行為**：cp \--reflink 會共享資料區塊，但會創建新的 Inode 與 Metadata（包含 mtime）。  
* **跨 Subvolume 限制**：Btrfs 的 reflink 通常不能跨越 Subvolume 邊界（例如不同的 Docker Layers 或 Datasets）。如果 Docker 嘗試重用 Layer 但底層觸發了完整的 copy（非 reflink），新檔案的 mtime 會是「現在」，這會立即讓所有基於舊 mtime 的快取失效。  
* **Cargo 的視角**：Cargo 的指紋機制雖然主要看內容雜湊，但其快速檢查路徑（Fast Path）依賴 mtime。如果 mtime 發生了劇烈變化（例如全部變成現在），Cargo 被迫進行內容雜湊計算。雖然理論上雜湊應該匹配，但配合上述的「絕對路徑污染」，只要路徑稍有不同，重編譯就不可避免。

## **6\. 詳細鑑識調查計畫（Forensic Investigation Plan）**

基於上述分析，我們制定了一套由淺入深的鑑識計畫。此計畫旨在精確定位導致 Dirty 的具體指紋欄位。

### **第一階段：啟用指紋追蹤日誌（High-Level Diagnostics）**

這是最關鍵的一步。Cargo 內建了詳細的指紋追蹤日誌，可以直接告訴我們「為什麼」它認為需要重編譯。  
**執行指令：**  
`CARGO_LOG=cargo::core::compiler::fingerprint=trace cargo build --verbose`

*注意：此指令會產生大量輸出，建議重定向到檔案進行分析。*  
**日誌分析重點：**

1. **搜尋關鍵字**：搜尋 fingerprint dirty for \<crate\_name\>。  
2. **判讀 Dirty 原因**：  
   * **mtime**：日誌會顯示 FileTime {... }\!= FileTime {... }。這表示 touch 策略失敗，檔案系統時間戳記仍有差異。  
   * **dep\_info**：日誌顯示 dependency info changed 或 paths changed。這強烈暗示 **絕對路徑污染**，.d 檔中的路徑與實際路徑不符 。  
   * **local**：日誌顯示 local fingerprint changed。這指向 **build.rs** 相關的變動（環境變數或 rerun-if-changed）。  
   * **precalculated**：日誌顯示 target configuration changed 或類似訊息。這指向 **RUSTFLAGS** 或 Profile 的變動。

### **第二階段：指紋資料鑑識（Metadata Forensics）**

如果日誌訊息不夠明確，我們需要直接檢查 Cargo 儲存的指紋檔案。  
**操作步驟：**

1. **定位指紋檔**：進入 target/debug/.fingerprint/\<crate\>-\<hash\>/。  
2. **比對 JSON**：該目錄下會有 \<hash\>.json 檔案。這是上一次成功建置的指紋快照。  
3. **差異分析**：  
   * 將該 JSON 檔案與當前環境（或另一個建置環境的 JSON）進行 Diff。  
   * 檢查 path 欄位：是否包含絕對路徑？路徑是否與當前目錄一致？  
   * 檢查 local 欄位：裡面記錄了哪些環境變數？其值是否與當前 shell 環境一致？  
   * 檢查 deps 欄位：依賴項的雜湊是否改變？這能追蹤是否因上游 crate 重編譯而導致的連鎖反應。

### **第三階段：二進位產物分析（Artifact Forensics）**

驗證絕對路徑是否被燒錄進了二進位檔，這會影響 sccache 的命中率。  
**操作步驟：**

1. **字串搜索**：  
   `strings target/debug/deps/lib<crate>.rlib | grep "$PWD"`  
   如果輸出了當前工作目錄的路徑，則證實了絕對路徑污染。  
2. **DWARF 分析**： 使用 llvm-dwarfdump 或 readelf 檢查 debug info。  
   `llvm-dwarfdump target/debug/deps/lib<crate>.rlib | grep DW_AT_comp_dir`  
   這會顯示編譯時的工作目錄（Compilation Directory）。如果此路徑是絕對路徑且隨環境變動，則必須進行路徑重映射。

### **第四階段：build.rs 行為審計**

針對被標記為 Dirty 的 crate，檢查其 build.rs 的輸出。  
**操作步驟：**

1. **查看執行輸出**：檢查 target/debug/build/\<crate\>-\<hash\>/output 檔案。  
2. **檢查指令**：尋找 cargo:rerun-if-changed 和 cargo:rerun-if-env-changed。  
3. **驗證路徑**：確認輸出的路徑是否存在？是否為絕對路徑？  
4. **驗證環境變數**：確認所有被監聽的環境變數在兩次建置之間是否保持恆定。特別注意那些由 CI 系統自動注入的變數。

## **7\. 修復與緩解策略（Mitigation Strategies）**

根據鑑識結果，可採取以下策略來修復非預期重編譯，實現真正的「時光倒流」或「快取復原」。

### **7.1 實施路徑重映射（Remap Path Prefix）—— 針對路徑污染**

這是解決絕對路徑污染的黃金標準，也是實現 Hermetic Builds 的關鍵。

* **操作**：在 .cargo/config.toml 中加入：  
  `[build]`  
  `rustflags = [`  
    `"--remap-path-prefix", "from_absolute_path=to_generic_path"`  
  `]`  
  通常會將當前工作區根目錄映射為 /src 或類似的固定字串。這樣無論專案在何處建置，嵌入的路徑指紋都是一致的 。

### **7.2 強制相對路徑依賴（Relative Dep-info）—— 針對 dep-in\[span\_10\](start\_span)\[span\_10\](end\_span)\[span\_12\](start\_span)\[span\_12\](end\_span)fo 失效**

設定 Cargo 使用相對路徑來記錄依賴關係，使 target 目錄可移植。

* **操作**：設定 build.dep-info-basedir。  
  `#.cargo/config.toml`  
  `[build]`  
  `dep-info-basedir = "."`  
  這會強迫 .d 檔案使用相對路徑，解決因目錄移動導致的 dep\_info 檢查失敗 。

### **7.3 使用 git-restore-mtime —— 針對 Mtime 精度問題**

如果問題確實在於 Git 或 Docker 導致的時間戳記混亂，應使用專門工具來恢復具有語義意義的時間戳記。

* **操作**：在建置前執行 git-restore-mtime。 這工具會根據 Git Commit 的時間來設定檔案 mtime，確保在任何機器上 checkout 出來的檔案時間戳記都是一致且「舊」的（相對於新生成的 Artifact），從而滿足 Cargo 的第一層檢查 。

### **7.4 穩定化 build.rs 環境**

* **操作**：審查所有 build.rs，確保它們只監聽必要的環境變數。  
* **技巧**：對於會波動的環境變數，可以在執行 cargo build 前顯式將其設為固定值，或者在 build.rs 中過濾掉不穩定的輸入。

## **8\. 結論**

當 find. \-exec touch... 失效時，我們面對的不再是單純的檔案同步問題，而是 Cargo 嚴格的指紋一致性檢查。透過本報告的分析，我們可以斷定「不新鮮（Dirty）」的理由極大機率源於**絕對路徑污染**導致的指紋雜湊不匹配，或是 **build.rs 對環境變數的隱性依賴**。  
鑑識的關鍵在於跳過表象的時間戳記，直接觀測 Cargo 內部的決策過程。透過啟用 cargo::core::compiler::fingerprint 的追蹤日誌，工程團隊可以精確定位是哪一個指紋欄位發生了漂移，進而採取路徑重映射或環境隔離等手段，從根本上解決快取失效問題，恢復建置系統的確定性與效率。

| 檢查層級 | 檢查對象 | 關鍵特徵 | 失效對策 |
| :---- | :---- | :---- | :---- |
| **L1: Mtime** | 檔案修改時間 | 奈秒精度，易受 cp/git 影響 | git-restore-mtime, touch |
| **L2: Fingerprint** | 建置組態與環境 | 包含路徑、Flags、Env Vars | remap-path-prefix, 固定 Env |
| **L3: Dep-info** | 依賴檔案路徑 | 預設絕對路徑，移動即失效 | dep-info-basedir |
| **L4: Sccache** | 編譯器呼叫指令 | 對絕對路徑參數極度敏感 | 統一建置路徑或重映射 |

**表 1：Cargo 快取失效層級與對策總表**

#### **引用的著作**

1.  *Module fingerprint - cargo::core::compiler - Rust Documentation*. Retrieved from <https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/index.html>
2.  *cargo::core::compiler::layout - Rust*. Retrieved from <https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/layout/index.html>
3.  *Fingerprint in cargo::core::compiler*. Retrieved from <https://doc.rust-lang.org/beta/nightly-rustc/cargo/core/compiler/fingerprint/struct.Fingerprint.html>
4.  *Build Cache - The Cargo Book - Rust Documentation*. Retrieved from <https://doc.rust-lang.org/cargo/reference/build-cache.html>
5.  *Remap source paths - The rustc book - Rust Documentation*. Retrieved from <https://doc.rust-lang.org/beta/rustc/remap-source-paths.html>
6.  *3127-trim-paths - The Rust RFC Book*. Retrieved from <https://rust-lang.github.io/rfcs/3127-trim-paths.html>
7.  *mozilla/sccache: Sccache is a ccache-like tool. It is used as a compiler wrapper and avoids compilation when possible. Sccache has the capability to utilize caching in remote storage environments, including various cloud storage options, or alternatively, in local storage*. GitHub. Retrieved from <https://github.com/mozilla/sccache>
8.  *Content-addressed cache? · Issue #964 · mozilla/sccache*. GitHub. Retrieved from <https://github.com/mozilla/sccache/issues/964>
9.  *Relative cargo:rerun-if-changed paths are not resolved in dep-info files #9445*. GitHub. Retrieved from <https://github.com/rust-lang/cargo/issues/9445>
10. *Cargo should skip rerun-if-changed paths to files in published crate sources · Issue #11083 · rust-lang/cargo*. GitHub. Retrieved from <https://github.com/rust-lang/cargo/issues/11083>
11. *Linker errors/build scripts cause build cache to become dirty · Issue #4385 · rust-lang/cargo*. Retrieved from <https://github.com/rust-lang/cargo/issues/4385>
12. *Rust analyzer and cargo cause rebuilds · Issue #17819*. GitHub. Retrieved from <https://github.com/rust-lang/rust-analyzer/issues/17819>
13. *Why does Rust cargo rebuild some packages a second time?* Stack Overflow. Retrieved from <https://stackoverflow.com/questions/68236372/why-does-rust-cargo-rebuild-some-packages-a-second-time>
14. *BTRFS storage driver*. Docker Docs. Retrieved from <https://docs.docker.com/engine/storage/drivers/btrfs-driver/>
15. *Storage drivers*. Docker Docs. Retrieved from <https://docs.docker.com/engine/storage/drivers/>
16. *Why does "cp -R --reflink=always" perform a standard copy on a Btrfs filesystem?* Unix & Linux Stack Exchange. Retrieved from <https://unix.stackexchange.com/questions/219280/why-does-cp-r-reflink-always-perform-a-standard-copy-on-a-btrfs-filesystem>
17. *How do I make Cargo show what files are causing a rebuild?* Stack Overflow. Retrieved from <https://stackoverflow.com/questions/70174147/how-do-i-make-cargo-show-what-files-are-causing-a-rebuild>
18. *Restore a file's modification time in Git*. Stack Overflow. Retrieved from <https://stackoverflow.com/questions/2458042/restore-a-files-modification-time-in-git>
