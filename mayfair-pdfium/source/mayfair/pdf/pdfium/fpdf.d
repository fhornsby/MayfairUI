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

/// How PDFium reads a document: a block at a time, from wherever the app keeps it.
struct FPDF_FILEACCESS
{
    c_ulong fileLength;
    extern (C) int function(void* param, c_ulong position, ubyte* buffer, c_ulong size) nothrow getBlock;
    void* param;
}

enum FPDFBitmap_BGRA = 4;
enum FPDF_ANNOT = 0x01;
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
