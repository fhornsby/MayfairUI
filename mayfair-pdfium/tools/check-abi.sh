#!/usr/bin/env sh
# Checks fpdf.d's hand-written PDFium declarations against the headers fetch.d downloaded with PDFium
# (in ../pdfium/include), or those in the folder given.
set -eu
cd "$(dirname "$0")"
include=${1:-../pdfium/include}
cc -I"$include" -fsyntax-only check-abi.c
echo "fpdf.d matches PDFium $(grep -o 'BUILD=[0-9]*' "$include/../VERSION" 2>/dev/null | cut -d= -f2)"
