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

// Editing, saving and forms
#include "fpdf_annot.h"
#include "fpdf_edit.h"
#include "fpdf_formfill.h"
#include "fpdf_fwlevent.h"
#include "fpdf_save.h"

SAME(FPDF_NO_INCREMENTAL, 1 << 1); SAME(FPDF_REMOVE_SECURITY, 1 << 2); SAME(FORMTYPE_NONE, 0);
SAME(FPDFANNOT_COLORTYPE_Color, 0); SAME(FPDFANNOT_COLORTYPE_InteriorColor, 1); SAME(FPDF_ANNOT_FLAG_PRINT, 1 << 2);
SAME(FPDF_FILLMODE_NONE, 0); SAME(FPDF_FILLMODE_WINDING, 2); SAME(FPDF_LINECAP_ROUND, 1); SAME(FPDF_LINEJOIN_ROUND, 1);
SAME(FWL_EVENTFLAG_ShiftKey, 1); SAME(FWL_EVENTFLAG_ControlKey, 2); SAME(FWL_EVENTFLAG_AltKey, 4);
SAME(FWL_VKEY_Back, 0x08); SAME(FWL_VKEY_Tab, 0x09); SAME(FWL_VKEY_Return, 0x0D); SAME(FWL_VKEY_Escape, 0x1B);
SAME(FWL_VKEY_Prior, 0x21); SAME(FWL_VKEY_Next, 0x22); SAME(FWL_VKEY_End, 0x23); SAME(FWL_VKEY_Home, 0x24);
SAME(FWL_VKEY_Left, 0x25); SAME(FWL_VKEY_Up, 0x26); SAME(FWL_VKEY_Right, 0x27); SAME(FWL_VKEY_Down, 0x28);
SAME(FWL_VKEY_Delete, 0x2E);
SAME(FPDF_ANNOT_UNKNOWN, 0); SAME(FPDF_ANNOT_TEXT, 1); SAME(FPDF_ANNOT_LINK, 2); SAME(FPDF_ANNOT_FREETEXT, 3);
SAME(FPDF_ANNOT_LINE, 4); SAME(FPDF_ANNOT_SQUARE, 5); SAME(FPDF_ANNOT_CIRCLE, 6); SAME(FPDF_ANNOT_POLYGON, 7);
SAME(FPDF_ANNOT_POLYLINE, 8); SAME(FPDF_ANNOT_HIGHLIGHT, 9); SAME(FPDF_ANNOT_UNDERLINE, 10);
SAME(FPDF_ANNOT_SQUIGGLY, 11); SAME(FPDF_ANNOT_STRIKEOUT, 12); SAME(FPDF_ANNOT_STAMP, 13); SAME(FPDF_ANNOT_INK, 15);
SAME(FPDF_ANNOT_POPUP, 16); SAME(FPDF_ANNOT_WIDGET, 20);

SAME(sizeof(FS_POINTF), 8); SAME(sizeof(FS_QUADPOINTSF), 32); SAME(offsetof(FS_QUADPOINTSF, x3), 16);
SAME(offsetof(FPDF_FILEWRITE, WriteBlock), 8); SAME(sizeof(FPDF_FILEWRITE), 16);
SAME(sizeof(FPDF_SYSTEMTIME), 16); SAME(offsetof(FPDF_SYSTEMTIME, wMilliseconds), 14);
SAME(offsetof(FPDF_FORMFILLINFO, Release), 8); SAME(offsetof(FPDF_FORMFILLINFO, FFI_Invalidate), 16);
SAME(offsetof(FPDF_FORMFILLINFO, FFI_OnChange), 64); SAME(offsetof(FPDF_FORMFILLINFO, FFI_GetPage), 72);
SAME(offsetof(FPDF_FORMFILLINFO, FFI_SetTextFieldFocus), 104); SAME(offsetof(FPDF_FORMFILLINFO, FFI_DoGoToAction), 120);
SAME(offsetof(FPDF_FORMFILLINFO, m_pJsPlatform), 128);
