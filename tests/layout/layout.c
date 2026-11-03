/* Reference layouts from the mingw-w64 headers shipped with Zig, printed as
 * "S <struct> <sizeof>" and "F <struct>.<generated field> <offsetof>".
 * tests/layout_test.zig compares every generated field against these lines.
 * Where the metadata names an anonymous union "Anonymous", the C side uses
 * the first member that union starts with (same offset). */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <oleauto.h>
#include <psapi.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <stddef.h>
#include <stdio.h>

#define S(T) printf("S %s %zu\n", #T, sizeof(T))
#define F(T, zig, c) printf("F %s.%s %zu\n", #T, zig, offsetof(T, c))
#define G(T, f) F(T, #f, f)

int main(void) {
    S(INPUT); G(INPUT, type); F(INPUT, "Anonymous", mi);
    S(MOUSEINPUT); G(MOUSEINPUT, dx); G(MOUSEINPUT, dy); G(MOUSEINPUT, mouseData); G(MOUSEINPUT, dwFlags); G(MOUSEINPUT, time); G(MOUSEINPUT, dwExtraInfo);
    S(KEYBDINPUT); G(KEYBDINPUT, wVk); G(KEYBDINPUT, wScan); G(KEYBDINPUT, dwFlags); G(KEYBDINPUT, time); G(KEYBDINPUT, dwExtraInfo);
    S(HARDWAREINPUT); G(HARDWAREINPUT, uMsg); G(HARDWAREINPUT, wParamL); G(HARDWAREINPUT, wParamH);
    S(DXGI_OUTDUPL_FRAME_INFO); G(DXGI_OUTDUPL_FRAME_INFO, LastPresentTime); G(DXGI_OUTDUPL_FRAME_INFO, LastMouseUpdateTime);
    G(DXGI_OUTDUPL_FRAME_INFO, AccumulatedFrames); G(DXGI_OUTDUPL_FRAME_INFO, RectsCoalesced); G(DXGI_OUTDUPL_FRAME_INFO, ProtectedContentMaskedOut);
    G(DXGI_OUTDUPL_FRAME_INFO, PointerPosition); G(DXGI_OUTDUPL_FRAME_INFO, TotalMetadataBufferSize); G(DXGI_OUTDUPL_FRAME_INFO, PointerShapeBufferSize);
    S(DXGI_OUTDUPL_DESC); G(DXGI_OUTDUPL_DESC, ModeDesc); G(DXGI_OUTDUPL_DESC, Rotation); G(DXGI_OUTDUPL_DESC, DesktopImageInSystemMemory);
    S(DXGI_OUTDUPL_POINTER_POSITION); G(DXGI_OUTDUPL_POINTER_POSITION, Position); G(DXGI_OUTDUPL_POINTER_POSITION, Visible);
    S(DXGI_OUTDUPL_MOVE_RECT); G(DXGI_OUTDUPL_MOVE_RECT, SourcePoint); G(DXGI_OUTDUPL_MOVE_RECT, DestinationRect);
    S(DXGI_OUTPUT_DESC); G(DXGI_OUTPUT_DESC, DeviceName); G(DXGI_OUTPUT_DESC, DesktopCoordinates); G(DXGI_OUTPUT_DESC, AttachedToDesktop);
    G(DXGI_OUTPUT_DESC, Rotation); G(DXGI_OUTPUT_DESC, Monitor);
    S(DXGI_ADAPTER_DESC1); G(DXGI_ADAPTER_DESC1, Description); G(DXGI_ADAPTER_DESC1, VendorId); G(DXGI_ADAPTER_DESC1, DeviceId);
    G(DXGI_ADAPTER_DESC1, SubSysId); G(DXGI_ADAPTER_DESC1, Revision); G(DXGI_ADAPTER_DESC1, DedicatedVideoMemory);
    G(DXGI_ADAPTER_DESC1, DedicatedSystemMemory); G(DXGI_ADAPTER_DESC1, SharedSystemMemory); G(DXGI_ADAPTER_DESC1, AdapterLuid); G(DXGI_ADAPTER_DESC1, Flags);
    S(DXGI_MODE_DESC); G(DXGI_MODE_DESC, Width); G(DXGI_MODE_DESC, Height); G(DXGI_MODE_DESC, RefreshRate); G(DXGI_MODE_DESC, Format);
    G(DXGI_MODE_DESC, ScanlineOrdering); G(DXGI_MODE_DESC, Scaling);
    S(DXGI_RATIONAL); G(DXGI_RATIONAL, Numerator); G(DXGI_RATIONAL, Denominator);
    S(DXGI_SAMPLE_DESC); G(DXGI_SAMPLE_DESC, Count); G(DXGI_SAMPLE_DESC, Quality);
    S(D3D11_TEXTURE2D_DESC); G(D3D11_TEXTURE2D_DESC, Width); G(D3D11_TEXTURE2D_DESC, Height); G(D3D11_TEXTURE2D_DESC, MipLevels);
    G(D3D11_TEXTURE2D_DESC, ArraySize); G(D3D11_TEXTURE2D_DESC, Format); G(D3D11_TEXTURE2D_DESC, SampleDesc); G(D3D11_TEXTURE2D_DESC, Usage);
    G(D3D11_TEXTURE2D_DESC, BindFlags); G(D3D11_TEXTURE2D_DESC, CPUAccessFlags); G(D3D11_TEXTURE2D_DESC, MiscFlags);
    S(D3D11_MAPPED_SUBRESOURCE); G(D3D11_MAPPED_SUBRESOURCE, pData); G(D3D11_MAPPED_SUBRESOURCE, RowPitch); G(D3D11_MAPPED_SUBRESOURCE, DepthPitch);
    S(VARIANT); F(VARIANT, "Anonymous", vt);
    S(SAFEARRAY); G(SAFEARRAY, cDims); G(SAFEARRAY, fFeatures); G(SAFEARRAY, cbElements); G(SAFEARRAY, cLocks); G(SAFEARRAY, pvData); G(SAFEARRAY, rgsabound);
    S(SAFEARRAYBOUND); G(SAFEARRAYBOUND, cElements); G(SAFEARRAYBOUND, lLbound);
    S(RECT); G(RECT, left); G(RECT, top); G(RECT, right); G(RECT, bottom);
    S(POINT); G(POINT, x); G(POINT, y);
    S(LUID); G(LUID, LowPart); G(LUID, HighPart);
    S(GUID); G(GUID, Data1); G(GUID, Data2); G(GUID, Data3); G(GUID, Data4);
    S(WNDCLASSEXW); G(WNDCLASSEXW, cbSize); G(WNDCLASSEXW, style); G(WNDCLASSEXW, lpfnWndProc); G(WNDCLASSEXW, cbClsExtra);
    G(WNDCLASSEXW, cbWndExtra); G(WNDCLASSEXW, hInstance); G(WNDCLASSEXW, hIcon); G(WNDCLASSEXW, hCursor); G(WNDCLASSEXW, hbrBackground);
    G(WNDCLASSEXW, lpszMenuName); G(WNDCLASSEXW, lpszClassName); G(WNDCLASSEXW, hIconSm);
    S(MSG); G(MSG, hwnd); G(MSG, message); G(MSG, wParam); G(MSG, lParam); G(MSG, time); G(MSG, pt);
    S(PAINTSTRUCT); G(PAINTSTRUCT, hdc); G(PAINTSTRUCT, fErase); G(PAINTSTRUCT, rcPaint); G(PAINTSTRUCT, fRestore); G(PAINTSTRUCT, fIncUpdate); G(PAINTSTRUCT, rgbReserved);
    S(PROCESS_MEMORY_COUNTERS_EX); G(PROCESS_MEMORY_COUNTERS_EX, cb); G(PROCESS_MEMORY_COUNTERS_EX, PageFaultCount); G(PROCESS_MEMORY_COUNTERS_EX, PeakWorkingSetSize);
    G(PROCESS_MEMORY_COUNTERS_EX, WorkingSetSize); G(PROCESS_MEMORY_COUNTERS_EX, QuotaPeakPagedPoolUsage); G(PROCESS_MEMORY_COUNTERS_EX, QuotaPagedPoolUsage);
    G(PROCESS_MEMORY_COUNTERS_EX, QuotaPeakNonPagedPoolUsage); G(PROCESS_MEMORY_COUNTERS_EX, QuotaNonPagedPoolUsage); G(PROCESS_MEMORY_COUNTERS_EX, PagefileUsage);
    G(PROCESS_MEMORY_COUNTERS_EX, PeakPagefileUsage); G(PROCESS_MEMORY_COUNTERS_EX, PrivateUsage);
    S(MONITORINFO); G(MONITORINFO, cbSize); G(MONITORINFO, rcMonitor); G(MONITORINFO, rcWork); G(MONITORINFO, dwFlags);
    S(DECIMAL); G(DECIMAL, wReserved); F(DECIMAL, "Anonymous1", scale); G(DECIMAL, Hi32); F(DECIMAL, "Anonymous2", Lo64);
    S(CY); F(CY, "Anonymous", Lo); G(CY, int64);
    return 0;
}
