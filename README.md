# CS 專題研究報告 (Special Topics on CS)

本專案用於整理「計算機科學專題」(Special Topics on Computer Science) 的相關文件，包含期中與期末報告的 LaTeX 原始碼、實驗數據、投影片及參考資料。

## 目錄結構

專案目錄結構如下：

*   **`src/`**: 報告的 LaTeX 原始碼 (`.tex`) 及相關資源檔。
    *   `midterm_report.tex`: 期中報告原始碼。
    *   `final_report.tex`: 期末報告原始碼。
*   **`report/`**: 編譯完成的 PDF 報告檔案存放處。
*   **`experiment/`**: 實驗相關的程式碼、數據或腳本。
*   **`slide/`**: 專題報告投影片。
*   **`docs/`**: 參考文件與文獻。
*   **`notes/`**: 會議記錄與筆記。

## 相依套件

在編譯本專案之前，請確保您的系統已安裝以下軟體及字型。

### LaTeX 環境

您需要一個包含 `XeLaTeX` 編譯器的 TeX 發行版。在 Arch Linux 上，您可以透過以下指令安裝：

```bash
paru -S texlive-core texlive-bin texlive-langchinese texlive-xetex
```

### 所需字型

本報告需要以下字型：

*   Liberation Serif
*   教育部標準楷書 (TW-MOE-Std-Kai)

您可以使用 `paru` 在 Arch Linux 上安裝它們：

```bash
paru -S ttf-liberation ttf-tw-moe-std-kai
```

## 編譯方式

本專案使用 `Makefile` 來簡化編譯流程。以下是幾個常用的指令：

*   **編譯所有報告**:
    同時編譯期中與期末報告。
    ```bash
    make all
    ```

*   **編譯期中報告** (`midterm_report.pdf`):
    ```bash
    make midterm
    ```

*   **編譯期末報告** (`final_report.pdf`):
    ```bash
    make final
    ```

*   **編譯範例文件** (`example.pdf`):
    ```bash
    make example
    ```

*   **編譯兩次以修正交互引用**:
    如果遇到引用 (citation) 或目錄相關的警告，請執行此指令（目前預設針對期中報告）。
    ```bash
    make twice
    ```

*   **清理暫存檔**:
    移除編譯過程中產生的 `.aux`, `.log` 等暫存檔案。
    ```bash
    make clean
    ```

*   **完整重新編譯**:
    先執行清理，然後再重新編譯所有報告。
    ```bash
    make rebuild
    ```

編譯完成後，產生的 PDF 檔案會存放在 `report/` 目錄下。