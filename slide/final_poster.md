### 海報標題 (Header)

**運用 Btrfs 寫入時複製機制加速 Rust 建置快取之研究**
A Study on Accelerating Rust Build Caching with Btrfs Copy-on-Write Mechanism

---

### 【左欄：問題與架構】 (Left Column: Context & Mechanism)

#### 1. 研究背景與動機 (Background & Motivation)

* **Rust 編譯痛點：** 隨著專案規模擴大，`target/` 目錄動輒數十 GB，編譯時間冗長。
* **多分支開發困境：** 切換 Git 分支 (`git checkout`) 會導致 `mtime` 變更，觸發 Cargo 不必要的重編譯；不同分支的 `target` 難以共存。
* **現有方案侷限：**
* `sccache`：不支援增量編譯 (Incremental)，且依賴實體檔案複製 (I/O 慢)。
* `Docker`：映像檔分層 (Layer) 粒度太粗，無法對應 Rust 檔案級快取。



#### 2. 核心技術機制 (Core Mechanisms)

* **Btrfs Reflink (CoW)：**
* 利用 `ioctl_ficlone` 實現 **O(1)** 檔案複製。
* 僅複製 Metadata (inode)，不複製實體資料區塊 (Data Blocks)，直到寫入才複製 (Copy-on-Write)。


* **Cargo 指紋 (Fingerprinting)：**
* **L1 時間戳記：** 檢查 `mtime` (本研究透過 `touch` 欺騙)。
* **L2 內容雜湊：** 檢查檔案內容、編譯參數、**絕對路徑**。



#### 3. 系統架構：Cargo-CoW (System Architecture)

*(建議在此放一張流程圖)*

1. **Seed Worktree：** 維護一份已編譯好的乾淨主分支 (`main`)。
2. **Snapshot：** 建立新分支時，使用 `cp --reflink` 瞬間複製 `Seed/target`。
3. **Restore：** 使用 `touch` 修正時間戳記，欺騙 Cargo 接受快取。
4. **Path Remapping：** 使用 `--remap-path-prefix` 消除 Rust 二進位檔中的路徑差異。

---

### 【右欄：實驗與展望】 (Right Column: Results & Future)

#### 4. 實驗結果 (Experimental Results)

**A. 空間效率 (Space Efficiency)**

* **測試對象：** `ripgrep` (多個 Worktree 共存)
* **邏輯大小：** 1.6 GB (Ext4)
* **物理大小：** **372 MB** (Btrfs + Zstd)
* **結果：** 節省 **77%** 空間，成本極低。

**B. 建置效能 (Performance)**
*(建議在此放長條圖對比)*

| 場景 | 專案 | 傳統方式 | Reflink 方式 | 結果 |
| --- | --- | --- | --- | --- |
| **冷啟動** | `ripgrep` | 4.09s | **2.80s** | **加速 1.46x** (成功) |
| **冷啟動** | `Zed` | 140s | 146s | **無效** (路徑污染導致重編) |
| **增量修改** | `ripgrep` | **0.67s** | 5.37s | **變慢** (固定開銷過大) |

#### 5. 關鍵分析 (Key Analysis)

* **固定開銷 (Fixed Overhead)：** Reflink 操作與環境建立約需 **2.5 秒**。這意味著此技術**不適合**微量修改 (Inner Loop)，但極適合 **CI/CD 環境重置**。
* **路徑污染 (Path Pollution)：** 在巨型專案 (`Zed`) 中，Cargo 的 Workspace 指紋與 C++ 編譯器會鎖定「絕對路徑」。單純的檔案系統還原無法騙過 Cargo，導致全量重編。

#### 6. 結論與未來展望 (Conclusion & Future Work)

* **結論：** Cargo-CoW 架構在「空間節省」上表現卓越，在「純 Rust 專案冷啟動」上有顯著加速。
* **未來方向 (解決路徑污染)：**
1. **容器化 (Containerization)：** 結合 Docker/Bubblewrap，將不同 Worktree 掛載至固定路徑 (`/workspace`)，徹底解決路徑雜湊不匹配問題。
2. **高速連結器 (Linker)：** 整合 `Mold` 或 `Wild`，解決增量編譯後期的 CPU 瓶頸。
3. **Reflink-aware Sccache：** 修改 sccache 後端支援 CoW，實現跨機器與本地的高效快取。


#### Reference


---

### 💡 製圖建議 (Visual Suggestions)

1. **左欄插圖：**
* **Btrfs vs Ext4 示意圖：** 畫出 Ext4 是「複製積木」，而 Btrfs 是「多個指標指向同一塊積木」。
* **流程圖：** `git worktree add` -> `cp --reflink` -> `touch -d` -> `cargo build`。


2. **右欄圖表：**
* **空間圓餅圖：** 顯示 "Shared Data" (77%) vs "Unique Data" (23%)。
* **時間長條圖：** 用 **堆疊長條圖 (Stacked Bar)** 顯示 `Reflink` 的時間構成（Setup I/O 時間 + 編譯時間），對比傳統的全量編譯時間。



這份大綱把你的「成功數據」與「失敗分析」都轉化為了強有力的學術論點，非常適合作為專題成果展示！
