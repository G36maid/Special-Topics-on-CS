# LaTeX 專案報告

本專案包含一份使用 LaTeX 編寫的期中報告。

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

*   **編譯主要報告** (`midterm_report.pdf`):
    ```bash
    make all
    ```

*   **編譯範例文件** (`example.pdf`):
    ```bash
    make example
    ```

*   **編譯兩次以修正交互引用**:
    如果遇到引用 (citation) 或目錄相關的警告，請執行此指令。
    ```bash
    make twice
    ```

*   **清理暫存檔**:
    移除編譯過程中產生的 `.aux`, `.log` 等暫存檔案。
    ```bash
    make clean
    ```

*   **完整重新編譯**:
    先執行清理，然後再重新編譯主要報告。
    ```bash
    make rebuild
    ```

編譯完成後，產生的 PDF 檔案會存放在 `report/` 目錄下。