/* US-001 witness probe: the same UIA snapshot as probe.zig, written in C
 * against the mingw-w64 headers, so Zig and C latencies can be compared on
 * the same target. Usage: probe_c [samples] [foreground|taskbar|0x<hwnd>] [full]
 *
 * `full` reads instead what neo-compute's snapshot reads in its main round
 * trip (src/backend/windows/uia.zig): one FindAllBuildCache on the window
 * element with the subtree of the control view, 12 properties and 9
 * patterns in the cache, the provider's cost of that read alone
 * (bench budgets relative to the provider, docs/decisions/0010). */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <uiautomation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int cmp_u64(const void *a, const void *b) {
    unsigned long long x = *(const unsigned long long *)a, y = *(const unsigned long long *)b;
    return x < y ? -1 : x > y;
}

static unsigned long long pct(const unsigned long long *v, int n, double p) {
    int rank = (int)(p * n + 0.999999);
    if (rank < 1) rank = 1;
    if (rank > n) rank = n;
    return v[rank - 1];
}

static HRESULT read_element(IUIAutomationElement *el) {
    BSTR name = NULL;
    CONTROLTYPEID type = 0;
    RECT r;
    HRESULT hr = IUIAutomationElement_get_CachedName(el, &name);
    SysFreeString(name);
    if (FAILED(hr)) return hr;
    hr = IUIAutomationElement_get_CachedControlType(el, &type);
    if (FAILED(hr)) return hr;
    return IUIAutomationElement_get_CachedBoundingRectangle(el, &r);
}

static HRESULT snapshot(IUIAutomation *uia, IUIAutomationCacheRequest *cache, IUIAutomationCondition *cond, HWND hwnd, int *count) {
    IUIAutomationElement *root = NULL;
    IUIAutomationElementArray *arr = NULL;
    BSTR live = NULL;
    int len = 0, i;
    HRESULT hr = IUIAutomation_ElementFromHandleBuildCache(uia, (UIA_HWND)hwnd, cache, &root);
    if (FAILED(hr)) return hr;
    hr = read_element(root);
    if (SUCCEEDED(hr)) hr = IUIAutomationElement_FindAllBuildCache(root, TreeScope_Descendants, cond, cache, &arr);
    if (SUCCEEDED(hr)) {
        hr = IUIAutomationElement_get_CurrentName(root, &live);
        SysFreeString(live);
    }
    if (SUCCEEDED(hr) && arr) {
        IUIAutomationElementArray_get_Length(arr, &len);
        for (i = 0; i < len && SUCCEEDED(hr); i++) {
            IUIAutomationElement *el = NULL;
            hr = IUIAutomationElementArray_GetElement(arr, i, &el);
            if (SUCCEEDED(hr)) {
                hr = read_element(el);
                IUIAutomationElement_Release(el);
            }
        }
    }
    if (arr) IUIAutomationElementArray_Release(arr);
    IUIAutomationElement_Release(root);
    *count = len + 1;
    return hr;
}

/* neo-compute's main read: ElementFromHandle, then FindAllBuildCache on the
 * window element (TreeScope_Element), the cache carrying the control-view
 * subtree. The cached tree is walked in process, as neo-compute does. */
static int count_cached(IUIAutomationElement *el) {
    IUIAutomationElementArray *children = NULL;
    int n = 1, len = 0, i;
    if (FAILED(IUIAutomationElement_GetCachedChildren(el, &children)) || !children) return n;
    IUIAutomationElementArray_get_Length(children, &len);
    for (i = 0; i < len; i++) {
        IUIAutomationElement *c = NULL;
        if (SUCCEEDED(IUIAutomationElementArray_GetElement(children, i, &c)) && c) {
            n += count_cached(c);
            IUIAutomationElement_Release(c);
        }
    }
    IUIAutomationElementArray_Release(children);
    return n;
}

static HRESULT snapshot_full(IUIAutomation *uia, IUIAutomationCacheRequest *cache, IUIAutomationCondition *cond, HWND hwnd, int *count) {
    IUIAutomationElement *live = NULL, *root = NULL;
    IUIAutomationElementArray *arr = NULL;
    int len = 0;
    HRESULT hr = IUIAutomation_ElementFromHandle(uia, (UIA_HWND)hwnd, &live);
    if (FAILED(hr)) return hr;
    hr = IUIAutomationElement_FindAllBuildCache(live, TreeScope_Element, cond, cache, &arr);
    if (SUCCEEDED(hr) && arr) {
        IUIAutomationElementArray_get_Length(arr, &len);
        if (len > 0 && SUCCEEDED(IUIAutomationElementArray_GetElement(arr, 0, &root)) && root) {
            *count = count_cached(root);
            IUIAutomationElement_Release(root);
        }
        IUIAutomationElementArray_Release(arr);
    }
    IUIAutomationElement_Release(live);
    return hr;
}

static const PROPERTYID full_properties[] = {
    UIA_RuntimeIdPropertyId, UIA_NamePropertyId, UIA_ControlTypePropertyId, UIA_BoundingRectanglePropertyId,
    UIA_IsOffscreenPropertyId, UIA_IsEnabledPropertyId, UIA_HasKeyboardFocusPropertyId, UIA_IsPasswordPropertyId,
    UIA_ValueValuePropertyId, UIA_ToggleToggleStatePropertyId, UIA_ExpandCollapseExpandCollapseStatePropertyId, UIA_SelectionItemIsSelectedPropertyId,
};
static const PATTERNID full_patterns[] = {
    UIA_InvokePatternId, UIA_ValuePatternId, UIA_TogglePatternId, UIA_ExpandCollapsePatternId, UIA_SelectionItemPatternId,
    UIA_ScrollItemPatternId, UIA_RangeValuePatternId, UIA_ScrollPatternId, UIA_TextPatternId,
};

int main(int argc, char **argv) {
    int samples = argc > 1 ? atoi(argv[1]) : 200;
    const char *target = argc > 2 ? argv[2] : "taskbar";
    int full = argc > 3 && strcmp(argv[3], "full") == 0;
    size_t k;
    IUIAutomation *uia = NULL;
    IUIAutomationCacheRequest *cache = NULL;
    IUIAutomationCondition *cond = NULL;
    LARGE_INTEGER freq, t0, t1;
    unsigned long long *lat;
    int i, count = 0;
    HWND hwnd;
    HRESULT hr;

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    /* "foreground", "taskbar", or a window handle such as 0x1a2b. */
    if (strncmp(target, "0x", 2) == 0) hwnd = (HWND)(uintptr_t)strtoull(target + 2, NULL, 16);
    else hwnd = strcmp(target, "foreground") == 0 ? GetForegroundWindow() : FindWindowW(L"Shell_TrayWnd", NULL);
    if (samples < 1 || !hwnd) return 2;
    lat = calloc((size_t)samples, sizeof(*lat));
    QueryPerformanceFrequency(&freq);

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (SUCCEEDED(hr)) hr = CoCreateInstance(&CLSID_CUIAutomation, NULL, CLSCTX_INPROC_SERVER, &IID_IUIAutomation, (void **)&uia);
    if (SUCCEEDED(hr)) hr = IUIAutomation_CreateCacheRequest(uia, &cache);
    if (full) {
        for (k = 0; SUCCEEDED(hr) && k < sizeof(full_properties) / sizeof(*full_properties); k++)
            hr = IUIAutomationCacheRequest_AddProperty(cache, full_properties[k]);
        for (k = 0; SUCCEEDED(hr) && k < sizeof(full_patterns) / sizeof(*full_patterns); k++)
            hr = IUIAutomationCacheRequest_AddPattern(cache, full_patterns[k]);
    } else {
        if (SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_AddProperty(cache, UIA_NamePropertyId);
        if (SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_AddProperty(cache, UIA_ControlTypePropertyId);
        if (SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_AddProperty(cache, UIA_BoundingRectanglePropertyId);
    }
    if (SUCCEEDED(hr)) hr = IUIAutomation_get_ControlViewCondition(uia, &cond);
    if (full && SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_put_TreeScope(cache, TreeScope_Subtree);
    if (full && SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_put_TreeFilter(cache, cond);
    for (i = 0; i < samples && SUCCEEDED(hr); i++) {
        QueryPerformanceCounter(&t0);
        hr = full ? snapshot_full(uia, cache, cond, hwnd, &count) : snapshot(uia, cache, cond, hwnd, &count);
        QueryPerformanceCounter(&t1);
        lat[i] = (unsigned long long)((t1.QuadPart - t0.QuadPart) * 1000000LL / freq.QuadPart);
    }
    if (FAILED(hr)) {
        fprintf(stderr, "probe_c: hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    qsort(lat, (size_t)samples, sizeof(*lat), cmp_u64);
    fprintf(stderr, "RESULT {\"snapshot_target\":\"%s\",\"read\":\"%s\",\"snapshot_elements\":%d,\"snapshot_p50_us\":%llu,\"snapshot_p95_us\":%llu,\"samples\":%d}\n",
            target, full ? "full" : "light", count, pct(lat, samples, 0.50), pct(lat, samples, 0.95), samples);
    IUIAutomationCondition_Release(cond);
    IUIAutomationCacheRequest_Release(cache);
    IUIAutomation_Release(uia);
    CoUninitialize();
    free(lat);
    return 0;
}
