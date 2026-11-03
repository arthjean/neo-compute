/* US-001 witness probe: the same UIA snapshot as probe.zig, written in C
 * against the mingw-w64 headers, so Zig and C latencies can be compared on
 * the same target. Usage: probe_c [samples] [foreground|taskbar] */
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

int main(int argc, char **argv) {
    int samples = argc > 1 ? atoi(argv[1]) : 200;
    const char *target = argc > 2 ? argv[2] : "taskbar";
    IUIAutomation *uia = NULL;
    IUIAutomationCacheRequest *cache = NULL;
    IUIAutomationCondition *cond = NULL;
    LARGE_INTEGER freq, t0, t1;
    unsigned long long *lat;
    int i, count = 0;
    HWND hwnd;
    HRESULT hr;

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    hwnd = strcmp(target, "foreground") == 0 ? GetForegroundWindow() : FindWindowW(L"Shell_TrayWnd", NULL);
    if (samples < 1 || !hwnd) return 2;
    lat = calloc((size_t)samples, sizeof(*lat));
    QueryPerformanceFrequency(&freq);

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (SUCCEEDED(hr)) hr = CoCreateInstance(&CLSID_CUIAutomation, NULL, CLSCTX_INPROC_SERVER, &IID_IUIAutomation, (void **)&uia);
    if (SUCCEEDED(hr)) hr = IUIAutomation_CreateCacheRequest(uia, &cache);
    if (SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_AddProperty(cache, UIA_NamePropertyId);
    if (SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_AddProperty(cache, UIA_ControlTypePropertyId);
    if (SUCCEEDED(hr)) hr = IUIAutomationCacheRequest_AddProperty(cache, UIA_BoundingRectanglePropertyId);
    if (SUCCEEDED(hr)) hr = IUIAutomation_get_ControlViewCondition(uia, &cond);
    for (i = 0; i < samples && SUCCEEDED(hr); i++) {
        QueryPerformanceCounter(&t0);
        hr = snapshot(uia, cache, cond, hwnd, &count);
        QueryPerformanceCounter(&t1);
        lat[i] = (unsigned long long)((t1.QuadPart - t0.QuadPart) * 1000000LL / freq.QuadPart);
    }
    if (FAILED(hr)) {
        fprintf(stderr, "probe_c: hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    qsort(lat, (size_t)samples, sizeof(*lat), cmp_u64);
    fprintf(stderr, "RESULT {\"snapshot_target\":\"%s\",\"snapshot_elements\":%d,\"snapshot_p50_us\":%llu,\"snapshot_p95_us\":%llu,\"samples\":%d}\n",
            target, count, pct(lat, samples, 0.50), pct(lat, samples, 0.95), samples);
    IUIAutomationCondition_Release(cond);
    IUIAutomationCacheRequest_Release(cache);
    IUIAutomation_Release(uia);
    CoUninitialize();
    free(lat);
    return 0;
}
