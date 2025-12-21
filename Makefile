# Makefile for LaTeX document compilation
# 使用 XeLaTeX 編譯器

# 變數定義
LATEX = xelatex
LATEXFLAGS = -interaction=nonstopmode -halt-on-error

SRC_DIR = src
REPORT_DIR = report

TARGET_NAME = midterm_report
EXAMPLE_NAME = example

TARGET = $(REPORT_DIR)/$(TARGET_NAME).pdf
EXAMPLE = $(REPORT_DIR)/$(EXAMPLE_NAME).pdf

SOURCES = $(SRC_DIR)/$(TARGET_NAME).tex
EXAMPLE_SRC = $(SRC_DIR)/$(EXAMPLE_NAME).tex

# 預設目標
.PHONY: all
all: $(TARGET)

# 建立 report 目錄
$(REPORT_DIR):
	mkdir -p $(REPORT_DIR)

# 編譯主要報告
$(TARGET): $(SOURCES) | $(REPORT_DIR)
	@echo "正在編譯 $(TARGET_NAME).tex ..."
	$(LATEX) $(LATEXFLAGS) -output-directory=$(SRC_DIR) $(SOURCES)
	mv $(SRC_DIR)/$(TARGET_NAME).pdf $(TARGET)
	@echo "編譯完成！報告位於 $(TARGET)"

# 編譯範例文件
.PHONY: example
example: $(EXAMPLE)

$(EXAMPLE): $(EXAMPLE_SRC) | $(REPORT_DIR)
	@echo "正在編譯 $(EXAMPLE_NAME).tex ..."
	$(LATEX) $(LATEXFLAGS) -output-directory=$(SRC_DIR) $(EXAMPLE_SRC)
	mv $(SRC_DIR)/$(EXAMPLE_NAME).pdf $(EXAMPLE)
	@echo "編譯完成！範例位於 $(EXAMPLE)"

# 編譯兩次以確保交叉引用正確
.PHONY: twice
twice: $(SOURCES) | $(REPORT_DIR)
	@echo "正在進行第一次編譯..."
	$(LATEX) $(LATEXFLAGS) -output-directory=$(SRC_DIR) $(SOURCES)
	@echo "正在進行第二次編譯..."
	$(LATEX) $(LATEXFLAGS) -output-directory=$(SRC_DIR) $(SOURCES)
	mv $(SRC_DIR)/$(TARGET_NAME).pdf $(TARGET)
	@echo "編譯完成！報告位於 $(TARGET)"

# 清理輔助檔案
.PHONY: clean
clean:
	@echo "清理輔助檔案..."
	rm -f $(SRC_DIR)/*.aux $(SRC_DIR)/*.log $(SRC_DIR)/*.out $(SRC_DIR)/*.toc $(SRC_DIR)/*.lof $(SRC_DIR)/*.lot $(SRC_DIR)/*.nav $(SRC_DIR)/*.snm $(SRC_DIR)/*.vrb $(SRC_DIR)/*.bbl $(SRC_DIR)/*.blg

# 完全清理（包含 PDF）
.PHONY: cleanall
cleanall: clean
	@echo "清理所有生成檔案..."
	rm -f $(TARGET) $(EXAMPLE)

# 檢視 PDF（使用系統預設程式）
.PHONY: view
view: $(TARGET)
	@echo "開啟 PDF 檔案..."
	xdg-open $(TARGET) 2>/dev/null || open $(TARGET) 2>/dev/null || echo "請手動開啟 $(TARGET)"

# 檢視範例 PDF
.PHONY: view-example
view-example: $(EXAMPLE)
	@echo "開啟範例 PDF 檔案..."
	xdg-open $(EXAMPLE) 2>/dev/null || open $(EXAMPLE) 2>/dev/null || echo "請手動開啟 $(EXAMPLE)"

# 重新編譯（先清理再編譯）
.PHONY: rebuild
rebuild: clean all

# 顯示幫助訊息
.PHONY: help
help:
	@echo "可用的 make 指令："
	@echo "  make          - 編譯主要報告 ($(TARGET))"
	@echo "  make example  - 編譯範例文件 ($(EXAMPLE))"
	@echo "  make twice    - 編譯兩次以確保交叉引用正確"
	@echo "  make clean    - 清理輔助檔案（保留 PDF）"
	@echo "  make cleanall - 清理所有生成檔案（包含 PDF）"
	@echo "  make view     - 開啟主要報告的 PDF"
	@echo "  make view-example - 開啟範例文件的 PDF"
	@echo "  make rebuild  - 清理後重新編譯"
	@echo "  make help     - 顯示此幫助訊息"
