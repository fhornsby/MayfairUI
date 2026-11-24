/*
    Checks what source/mayfair/pdf/pdfium/fpdf.d declares by hand against PDFium's own headers:
    the constants, and the layout of each struct passed. Run by check-abi.sh; it compiles only if
    they agree.
*/
#include <stddef.h>
#include "fpdfview.h"
#include "fpdf_text.h"
#include "fpdf_doc.h"

#define SAME(a, b) _Static_assert((a) == (b), #a " isn't " #b ": update fpdf.d")

SAME(FPDFBitmap_BGRA, 4); SAME(FPDF_ANNOT, 0x01);
SAME(FPDF_ERR_SUCCESS, 0); SAME(FPDF_ERR_UNKNOWN, 1); SAME(FPDF_ERR_FILE, 2); SAME(FPDF_ERR_FORMAT, 3);
SAME(FPDF_ERR_PASSWORD, 4); SAME(FPDF_ERR_SECURITY, 5); SAME(FPDF_ERR_PAGE, 6);
SAME(PDFACTION_UNSUPPORTED, 0); SAME(PDFACTION_GOTO, 1); SAME(PDFACTION_REMOTEGOTO, 2); SAME(PDFACTION_URI, 3);
SAME(PDFACTION_LAUNCH, 4);

SAME(sizeof(FS_MATRIX), 24); SAME(offsetof(FS_MATRIX, e), 16);
SAME(sizeof(FS_RECTF), 16); SAME(offsetof(FS_RECTF, top), 4); SAME(offsetof(FS_RECTF, right), 8);
SAME(sizeof(FS_SIZEF), 8);
SAME(offsetof(FPDF_LIBRARY_CONFIG, version), 0); SAME(offsetof(FPDF_LIBRARY_CONFIG, m_pUserFontPaths), 8);
SAME(offsetof(FPDF_LIBRARY_CONFIG, m_pIsolate), 16); SAME(offsetof(FPDF_LIBRARY_CONFIG, m_v8EmbedderSlot), 24);
SAME(offsetof(FPDF_LIBRARY_CONFIG, m_pPlatform), 32);
SAME(offsetof(FPDF_FILEACCESS, m_FileLen), 0); SAME(offsetof(FPDF_FILEACCESS, m_GetBlock), 8);
SAME(offsetof(FPDF_FILEACCESS, m_Param), 16);
