# Makefile for LaTeX document compilation
# 使用 XeLaTeX 編譯器

# 變數定義
LATEX = xelatex
LATEXFLAGS = -interaction=nonstopmode -halt-on-error
TARGET = midterm_report
EXAMPLE = example
SOURCES = $(TARGET).tex
EXAMPLE_SRC = $(EXAMPLE).tex

# 預設目標
.PHONY: all
all: $(TARGET).pdf

# 編譯主要報告
$(TARGET).pdf: $(SOURCES)
	@echo "正在編譯 $(TARGET).tex ..."
	$(LATEX) $(LATEXFLAGS) $(TARGET).tex
	@echo "編譯完成！"

# 編譯範例文件
.PHONY: example
example: $(EXAMPLE).pdf

$(EXAMPLE).pdf: $(EXAMPLE_SRC)
	@echo "正在編譯 $(EXAMPLE).tex ..."
	$(LATEX) $(LATEXFLAGS) $(EXAMPLE).tex
	@echo "編譯完成！"

# 編譯兩次以確保交叉引用正確
.PHONY: twice
twice:
	@echo "正在進行第一次編譯..."
	$(LATEX) $(LATEXFLAGS) $(TARGET).tex
	@echo "正在進行第二次編譯..."
	$(LATEX) $(LATEXFLAGS) $(TARGET).tex
	@echo "編譯完成！"

# 清理輔助檔案
.PHONY: clean
clean:
	@echo "清理輔助檔案..."
	rm -f *.aux *.log *.out *.toc *.lof *.lot *.nav *.snm *.vrb *.bbl *.blg

# 完全清理（包含 PDF）
.PHONY: cleanall
cleanall: clean
	@echo "清理所有生成檔案..."
	rm -f $(TARGET).pdf $(EXAMPLE).pdf

# 檢視 PDF（使用系統預設程式）
.PHONY: view
view: $(TARGET).pdf
	@echo "開啟 PDF 檔案..."
	xdg-open $(TARGET).pdf 2>/dev/null || open $(TARGET).pdf 2>/dev/null || echo "請手動開啟 $(TARGET).pdf"

# 檢視範例 PDF
.PHONY: view-example
view-example: $(EXAMPLE).pdf
	@echo "開啟範例 PDF 檔案..."
	xdg-open $(EXAMPLE).pdf 2>/dev/null || open $(EXAMPLE).pdf 2>/dev/null || echo "請手動開啟 $(EXAMPLE).pdf"

# 重新編譯（先清理再編譯）
.PHONY: rebuild
rebuild: clean all

# 顯示幫助訊息
.PHONY: help
help:
	@echo "可用的 make 指令："
	@echo "  make          - 編譯主要報告 ($(TARGET).pdf)"
	@echo "  make example  - 編譯範例文件 ($(EXAMPLE).pdf)"
	@echo "  make twice    - 編譯兩次以確保交叉引用正確"
	@echo "  make clean    - 清理輔助檔案（保留 PDF）"
	@echo "  make cleanall - 清理所有生成檔案（包含 PDF）"
	@echo "  make view     - 開啟主要報告的 PDF"
	@echo "  make view-example - 開啟範例文件的 PDF"
	@echo "  make rebuild  - 清理後重新編譯"
	@echo "  make help     - 顯示此幫助訊息"
