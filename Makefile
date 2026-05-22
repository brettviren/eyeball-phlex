DOT_SRCS  := $(wildcard *.dot)
PUML_SRCS := $(wildcard *.puml)

PDFS := $(DOT_SRCS:.dot=.pdf)  $(PUML_SRCS:.puml=.pdf)
PNGS := $(DOT_SRCS:.dot=.png)  $(PUML_SRCS:.puml=.png)
SVGS := $(DOT_SRCS:.dot=.svg)  $(PUML_SRCS:.puml=.svg)

.PHONY: all all_pdf all_png all_svg

all: all_pdf all_png all_svg
all_pdf: $(PDFS)
all_png: $(PNGS)
all_svg: $(SVGS)

%.pdf: %.dot
	dot -Tpdf $< -o $@

%.png: %.dot
	dot -Tpng $< -o $@

%.svg: %.dot
	dot -Tsvg $< -o $@

%.pdf: %.puml
	plantuml -tsvg $<
	rsvg-convert -f pdf -o $@ $(<:.puml=.svg)

%.png: %.puml
	plantuml -tpng $<

%.svg: %.puml
	plantuml -tsvg $<
