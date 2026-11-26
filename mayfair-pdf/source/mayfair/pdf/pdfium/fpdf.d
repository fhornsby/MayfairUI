module mayfair.pdf.pdfium.fpdf;

/*
    The part of PDFium's C API this engine uses, found at run time rather than linked, so an app
    builds without PDFium, and one run where it's missing says so. Hand-written, and checked
    against PDFium's own headers by tools/check-abi.sh. PDFium's API is stable: these are all in
    every PDFium of the last several years.
*/

import core.stdc.config : c_ulong;

alias FPDF_BOOL = int;

struct FS_MATRIX { float a = 1, b = 0, c = 0, d = 1, e = 0, f = 0; }
struct FS_RECTF { float left = 0, top = 0, right = 0, bottom = 0; }
struct FS_SIZEF { float width = 0, height = 0; }
struct FS_POINTF { float x = 0, y = 0; }
struct FS_QUADPOINTSF { float x1 = 0, y1 = 0, x2 = 0, y2 = 0, x3 = 0, y3 = 0, x4 = 0, y4 = 0; }

/// How PDFium writes a document out: a block at a time, wherever the app wants.
struct FPDF_FILEWRITE
{
    int version_ = 1;
    extern (C) int function(FPDF_FILEWRITE* self, const(void)* data, c_ulong size) nothrow WriteBlock;
}

struct FPDF_SYSTEMTIME
{
    ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
}

/// FPDF_FORMFILLINFO, as far as its version 1: what a form calls back with.
struct FPDF_FORMFILLINFO
{
extern (C) nothrow:
    int version_ = 1;
    void function(FPDF_FORMFILLINFO*) Release;
    void function(FPDF_FORMFILLINFO*, void* page, double left, double top, double right, double bottom) FFI_Invalidate;
    void function(FPDF_FORMFILLINFO*, void* page, double left, double top, double right, double bottom) FFI_OutputSelectedRect;
    void function(FPDF_FORMFILLINFO*, int cursor) FFI_SetCursor;
    int function(FPDF_FORMFILLINFO*, int elapse, void function(int) timer) FFI_SetTimer;
    void function(FPDF_FORMFILLINFO*, int id) FFI_KillTimer;
    FPDF_SYSTEMTIME function(FPDF_FORMFILLINFO*) FFI_GetLocalTime;
    void function(FPDF_FORMFILLINFO*) FFI_OnChange;
    void* function(FPDF_FORMFILLINFO*, void* document, int index) FFI_GetPage;
    void* function(FPDF_FORMFILLINFO*, void* document) FFI_GetCurrentPage;
    int function(FPDF_FORMFILLINFO*, void* page) FFI_GetRotation;
    void function(FPDF_FORMFILLINFO*, const(char)* action) FFI_ExecuteNamedAction;
    void function(FPDF_FORMFILLINFO*, const(ushort)* value, c_ulong length, int focused) FFI_SetTextFieldFocus;
    void function(FPDF_FORMFILLINFO*, const(char)* uri) FFI_DoURIAction;
    void function(FPDF_FORMFILLINFO*, int page, int zoomMode, float* position, int count) FFI_DoGoToAction;
    void* m_pJsPlatform;
}

/// FPDF_LIBRARY_CONFIG, as far as its version 2: what every PDFium reads.
struct FPDF_LIBRARY_CONFIG
{
    int version_ = 2;
    const(char)** userFontPaths;
    void* isolate;
    uint v8EmbedderSlot;
    void* platform;
}
static assert(FPDF_LIBRARY_CONFIG.platform.offsetof == 32);
// As tools/check-abi.c checks the headers have them
static assert(FPDF_FILEWRITE.WriteBlock.offsetof == 8 && FPDF_FILEWRITE.sizeof == 16);
static assert(FPDF_FORMFILLINFO.FFI_OnChange.offsetof == 64 && FPDF_FORMFILLINFO.FFI_SetTextFieldFocus.offsetof == 104);
static assert(FPDF_FORMFILLINFO.m_pJsPlatform.offsetof == 128 && FPDF_SYSTEMTIME.sizeof == 16);

/// How PDFium reads a document: a block at a time, from wherever the app keeps it.
struct FPDF_FILEACCESS
{
    c_ulong fileLength;
    extern (C) int function(void* param, c_ulong position, ubyte* buffer, c_ulong size) nothrow getBlock;
    void* param;
}

enum FPDFBitmap_BGRA = 4;
enum FPDF_ANNOT = 0x01;
enum FPDF_NO_INCREMENTAL = 1 << 1, FPDF_REMOVE_SECURITY = 1 << 2;
enum FORMTYPE_NONE = 0;
enum FPDFANNOT_COLORTYPE_Color = 0, FPDFANNOT_COLORTYPE_InteriorColor = 1;
enum FPDF_ANNOT_FLAG_PRINT = 1 << 2;
enum FPDF_FILLMODE_NONE = 0, FPDF_FILLMODE_WINDING = 2;
enum FPDF_LINECAP_ROUND = 1, FPDF_LINEJOIN_ROUND = 1;
enum FWL_EVENTFLAG_ShiftKey = 1, FWL_EVENTFLAG_ControlKey = 2, FWL_EVENTFLAG_AltKey = 4;
enum
{
    FWL_VKEY_Back = 0x08, FWL_VKEY_Tab = 0x09, FWL_VKEY_Return = 0x0D, FWL_VKEY_Escape = 0x1B,
    FWL_VKEY_Prior = 0x21, FWL_VKEY_Next = 0x22, FWL_VKEY_End = 0x23, FWL_VKEY_Home = 0x24,
    FWL_VKEY_Left = 0x25, FWL_VKEY_Up = 0x26, FWL_VKEY_Right = 0x27, FWL_VKEY_Down = 0x28,
    FWL_VKEY_Delete = 0x2E,
}
enum
{
    FPDF_ANNOT_UNKNOWN = 0, FPDF_ANNOT_TEXT = 1, FPDF_ANNOT_LINK = 2, FPDF_ANNOT_FREETEXT = 3,
    FPDF_ANNOT_LINE = 4, FPDF_ANNOT_SQUARE = 5, FPDF_ANNOT_CIRCLE = 6, FPDF_ANNOT_POLYGON = 7,
    FPDF_ANNOT_POLYLINE = 8, FPDF_ANNOT_HIGHLIGHT = 9, FPDF_ANNOT_UNDERLINE = 10,
    FPDF_ANNOT_SQUIGGLY = 11, FPDF_ANNOT_STRIKEOUT = 12, FPDF_ANNOT_STAMP = 13, FPDF_ANNOT_INK = 15,
    FPDF_ANNOT_POPUP = 16, FPDF_ANNOT_WIDGET = 20,
}
enum : c_ulong
{
    FPDF_ERR_SUCCESS = 0,
    FPDF_ERR_UNKNOWN = 1,
    FPDF_ERR_FILE = 2,
    FPDF_ERR_FORMAT = 3,
    FPDF_ERR_PASSWORD = 4,
    FPDF_ERR_SECURITY = 5,
    FPDF_ERR_PAGE = 6,
}
enum : c_ulong
{
    PDFACTION_UNSUPPORTED = 0,
    PDFACTION_GOTO = 1,
    PDFACTION_REMOTEGOTO = 2,
    PDFACTION_URI = 3,
    PDFACTION_LAUNCH = 4,
}

/// PDFium's functions, by their names.
struct Functions
{
extern (C) nothrow @nogc:
    void function(const(FPDF_LIBRARY_CONFIG)*) FPDF_InitLibraryWithConfig;
    void function() FPDF_DestroyLibrary;
    c_ulong function() FPDF_GetLastError;
    void* function(FPDF_FILEACCESS*, const(char)*) FPDF_LoadCustomDocument;
    void function(void*) FPDF_CloseDocument;
    int function(void*) FPDF_GetPageCount;
    FPDF_BOOL function(void*, int, FS_SIZEF*) FPDF_GetPageSizeByIndexF;
    void* function(void*, int) FPDF_LoadPage;
    void function(void*) FPDF_ClosePage;
    FPDF_BOOL function(void*, int, int, int, int, int, double, double, int*, int*) FPDF_PageToDevice;
    c_ulong function(void*, const(char)*, void*, c_ulong) FPDF_GetMetaText;

    void* function(int, int, int, void*, int) FPDFBitmap_CreateEx;
    FPDF_BOOL function(void*, int, int, int, int, uint) FPDFBitmap_FillRect;
    void function(void*) FPDFBitmap_Destroy;
    void function(void*, void*, const(FS_MATRIX)*, const(FS_RECTF)*, int) FPDF_RenderPageBitmapWithMatrix;

    void* function(void*) FPDFText_LoadPage;
    void function(void*) FPDFText_ClosePage;
    int function(void*) FPDFText_CountChars;
    uint function(void*, int) FPDFText_GetUnicode;
    FPDF_BOOL function(void*, int, double*, double*, double*, double*) FPDFText_GetCharBox;

    void* function(void*) FPDFLink_LoadWebLinks;
    int function(void*) FPDFLink_CountWebLinks;
    int function(void*, int, ushort*, int) FPDFLink_GetURL;
    int function(void*, int) FPDFLink_CountRects;
    FPDF_BOOL function(void*, int, int, double*, double*, double*, double*) FPDFLink_GetRect;
    void function(void*) FPDFLink_CloseWebLinks;
    FPDF_BOOL function(void*, int*, void**) FPDFLink_Enumerate;
    FPDF_BOOL function(void*, FS_RECTF*) FPDFLink_GetAnnotRect;
    void* function(void*, void*) FPDFLink_GetDest;
    void* function(void*) FPDFLink_GetAction;

    c_ulong function(void*) FPDFAction_GetType;
    void* function(void*, void*) FPDFAction_GetDest;
    c_ulong function(void*, void*, void*, c_ulong) FPDFAction_GetURIPath;
    int function(void*, void*) FPDFDest_GetDestPageIndex;
    FPDF_BOOL function(void*, FPDF_BOOL*, FPDF_BOOL*, FPDF_BOOL*, float*, float*, float*) FPDFDest_GetLocationInPage;

    void* function(void*, void*) FPDFBookmark_GetFirstChild;
    void* function(void*, void*) FPDFBookmark_GetNextSibling;
    c_ulong function(void*, void*, c_ulong) FPDFBookmark_GetTitle;
    void* function(void*, void*) FPDFBookmark_GetDest;
    void* function(void*) FPDFBookmark_GetAction;

    // What a document is
    FPDF_BOOL function(void*, int*) FPDF_GetFileVersion;
    int function(void*) FPDF_GetSecurityHandlerRevision;
    int function(void*) FPDF_GetFormType;
    FPDF_BOOL function(void*, int, int, int, int, int, int, int, double*, double*) FPDF_DeviceToPage;
    void function(void*, void*, int, int, int, int, int, int) FPDF_RenderPageBitmap;

    // Saving, and opening what was saved
    FPDF_BOOL function(void*, FPDF_FILEWRITE*, c_ulong) FPDF_SaveAsCopy;
    void* function(const(void)*, size_t, const(char)*) FPDF_LoadMemDocument64;

    // Pages
    void function(void*, int) FPDFPage_SetRotation;
    int function(void*) FPDFPage_GetRotation;
    void function(void*, int) FPDFPage_Delete;
    FPDF_BOOL function(void*, const(int)*, c_ulong, int) FPDF_MovePages;
    void* function(void*, int, double, double) FPDFPage_New;
    FPDF_BOOL function(void*, void*, const(int)*, c_ulong, int) FPDF_ImportPagesByIndex;
    void function(void*, float, float, float, float) FPDFPage_SetCropBox;

    // Annotations
    int function(void*) FPDFPage_GetAnnotCount;
    void* function(void*, int) FPDFPage_GetAnnot;
    void function(void*) FPDFPage_CloseAnnot;
    void* function(void*, int) FPDFPage_CreateAnnot;
    FPDF_BOOL function(void*, int) FPDFPage_RemoveAnnot;
    int function(void*, void*) FPDFPage_GetAnnotIndex;
    int function(void*) FPDFAnnot_GetSubtype;
    FPDF_BOOL function(void*, FS_RECTF*) FPDFAnnot_GetRect;
    FPDF_BOOL function(void*, const(FS_RECTF)*) FPDFAnnot_SetRect;
    FPDF_BOOL function(void*, int, uint, uint, uint, uint) FPDFAnnot_SetColor;
    FPDF_BOOL function(void*, const(FS_QUADPOINTSF)*) FPDFAnnot_AppendAttachmentPoints;
    size_t function(void*) FPDFAnnot_CountAttachmentPoints;
    FPDF_BOOL function(void*, size_t, FS_QUADPOINTSF*) FPDFAnnot_GetAttachmentPoints;
    int function(void*, const(FS_POINTF)*, size_t) FPDFAnnot_AddInkStroke;
    c_ulong function(void*) FPDFAnnot_GetInkListCount;
    c_ulong function(void*, c_ulong, FS_POINTF*, c_ulong) FPDFAnnot_GetInkListPath;
    FPDF_BOOL function(void*, float, float, float) FPDFAnnot_SetBorder;
    FPDF_BOOL function(void*, const(char)*, const(ushort)*) FPDFAnnot_SetStringValue;
    c_ulong function(void*, const(char)*, ushort*, c_ulong) FPDFAnnot_GetStringValue;
    FPDF_BOOL function(void*, void*) FPDFAnnot_AppendObject;
    FPDF_BOOL function(void*, FS_POINTF*, FS_POINTF*) FPDFAnnot_GetLine;
    int function(void*, void*) FPDFAnnot_GetFormFieldType;
    FPDF_BOOL function(void*, int) FPDFAnnot_SetFlags;

    // What annotations are drawn with
    void* function(float, float) FPDFPageObj_CreateNewPath;
    FPDF_BOOL function(void*, float, float) FPDFPath_MoveTo;
    FPDF_BOOL function(void*, float, float) FPDFPath_LineTo;
    FPDF_BOOL function(void*, float, float, float, float, float, float) FPDFPath_BezierTo;
    FPDF_BOOL function(void*) FPDFPath_Close;
    FPDF_BOOL function(void*, int, FPDF_BOOL) FPDFPath_SetDrawMode;
    FPDF_BOOL function(void*, uint, uint, uint, uint) FPDFPageObj_SetStrokeColor;
    FPDF_BOOL function(void*, uint, uint, uint, uint) FPDFPageObj_SetFillColor;
    FPDF_BOOL function(void*, float) FPDFPageObj_SetStrokeWidth;
    FPDF_BOOL function(void*, int) FPDFPageObj_SetLineJoin;
    FPDF_BOOL function(void*, int) FPDFPageObj_SetLineCap;
    void* function(void*, const(char)*, float) FPDFPageObj_NewTextObj;
    FPDF_BOOL function(void*, const(ushort)*) FPDFText_SetText;
    void function(void*, double, double, double, double, double, double) FPDFPageObj_Transform;
    FPDF_BOOL function(void*, float*, float*, float*, float*) FPDFPageObj_GetBounds;
    void function(void*) FPDFPageObj_Destroy;

    // Forms
    void* function(void*, FPDF_FORMFILLINFO*) FPDFDOC_InitFormFillEnvironment;
    void function(void*) FPDFDOC_ExitFormFillEnvironment;
    void function(void*, void*) FORM_OnAfterLoadPage;
    void function(void*, void*) FORM_OnBeforeClosePage;
    void function(void*, void*, void*, int, int, int, int, int, int) FPDF_FFLDraw;
    FPDF_BOOL function(void*, void*, int, double, double) FORM_OnMouseMove;
    FPDF_BOOL function(void*, void*, int, double, double) FORM_OnLButtonDown;
    FPDF_BOOL function(void*, void*, int, double, double) FORM_OnLButtonUp;
    FPDF_BOOL function(void*, void*, int, double, double) FORM_OnLButtonDoubleClick;
    FPDF_BOOL function(void*, void*, int, int) FORM_OnKeyDown;
    FPDF_BOOL function(void*, void*, int, int) FORM_OnKeyUp;
    FPDF_BOOL function(void*, void*, int, int) FORM_OnChar;
    FPDF_BOOL function(void*) FORM_ForceToKillFocus;
    FPDF_BOOL function(void*, int*, void**) FORM_GetFocusedAnnot;
    c_ulong function(void*, void*, void*, c_ulong) FORM_GetSelectedText;
    void function(void*, void*, const(ushort)*) FORM_ReplaceSelection;
    FPDF_BOOL function(void*, void*) FORM_SelectAllText;
    FPDF_BOOL function(void*, void*) FORM_Undo;
    FPDF_BOOL function(void*, void*) FORM_Redo;
    void function(void*, int, c_ulong) FPDF_SetFormFieldHighlightColor;
    void function(void*, ubyte) FPDF_SetFormFieldHighlightAlpha;
}

/// PDFium, opened from `library`: false, with `failure` saying why, if it couldn't be, or hasn't all of `Functions`.
bool loadPdfium(string library, ref Functions fn, out string failure)
{
    import std.string : fromStringz, toStringz;
    version (Windows)
    {
        import core.sys.windows.winbase : GetProcAddress, LoadLibraryA;
        import core.sys.windows.windef : HMODULE;
        auto lib = cast(void*) LoadLibraryA(library.toStringz);
        if (!lib)
        {
            failure = "couldn't load " ~ library;
            return false;
        }
        void* symbol(string name) { return cast(void*) GetProcAddress(cast(HMODULE) lib, name.toStringz); }
    }
    else
    {
        import core.sys.posix.dlfcn : dlerror, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
        auto lib = dlopen(library.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (!lib)
        {
            auto why = dlerror();
            failure = why ? fromStringz(why).idup : "couldn't load " ~ library;
            return false;
        }
        void* symbol(string name) { return dlsym(lib, name.toStringz); }
    }
    static foreach (member; __traits(allMembers, Functions))
    {{
        auto f = symbol(member);
        if (!f)
        {
            failure = library ~ " has no " ~ member ~ ": it's too old a PDFium";
            return false;
        }
        mixin("fn." ~ member ~ " = cast(typeof(fn." ~ member ~ ")) f;");
    }}
    return true;
}
