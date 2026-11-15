using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class Panel {
    delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX {
        public int cbSize; public uint style; public WndProc lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l; public int t; public int r; public int b; }
    [StructLayout(LayoutKind.Sequential)]
    struct PAINTSTRUCT {
        public IntPtr hdc; public int fErase; public RECT rc; public int fRestore; public int fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] reserved;
    }
    [StructLayout(LayoutKind.Sequential)] struct ICC { public int size; public uint classes; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int c);
    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)] static extern IntPtr SendText(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)] static extern IntPtr ReadText(IntPtr h, uint m, IntPtr w, StringBuilder l);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr Send(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr h, UIntPtr id, uint ms, IntPtr f);
    [DllImport("user32.dll")] static extern IntPtr BeginPaint(IntPtr h, out PAINTSTRUCT p);
    [DllImport("user32.dll")] static extern bool EndPaint(IntPtr h, ref PAINTSTRUCT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int DrawTextW(IntPtr dc, string s, int n, ref RECT r, uint f);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern IntPtr LoadCursorW(IntPtr inst, IntPtr name);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateFontW(int h, int w, int esc, int ori, int weight, uint italic, uint underline, uint strike, uint charset, uint outp, uint clip, uint quality, uint pitch, string face);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern int SetBkMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern uint SetTextColor(IntPtr dc, uint c);
    [DllImport("comctl32.dll")] static extern bool InitCommonControlsEx(ref ICC i);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);

    const uint Child = 0x50000000;
    static readonly string[] Qualities = { "Brouillon", "Normale", "Haute", "Maximale" };
    static readonly string[] Cities = {
        "Agen", "Aix-en-Provence", "Ajaccio", "Albi", "Alençon", "Amiens", "Angers", "Angoulême", "Annecy", "Antibes",
        "Arles", "Arras", "Aurillac", "Auxerre", "Avignon", "Bastia", "Bayonne", "Beauvais", "Belfort", "Bergerac",
        "Besançon", "Béziers", "Blois", "Bordeaux", "Bourges", "Brest", "Brive-la-Gaillarde", "Caen", "Cahors", "Calais",
        "Cannes", "Carcassonne", "Chalon-sur-Saône", "Chambéry", "Charleville-Mézières", "Chartres", "Châteauroux", "Cherbourg", "Cholet", "Clermont-Ferrand",
        "Cognac", "Colmar", "Compiègne", "Dax", "Dieppe", "Dijon", "Draguignan", "Dunkerque", "Épinal", "Évreux",
        "Foix", "Fréjus", "Gap", "Grenoble", "Guéret", "La Rochelle", "Laon", "Laval", "Le Havre", "Le Mans",
        "Lens", "Lille", "Limoges", "Lorient", "Lyon", "Mâcon", "Marseille", "Meaux", "Melun", "Mende",
        "Metz", "Montauban", "Montpellier", "Moulins", "Mulhouse", "Nancy", "Nantes", "Narbonne", "Nevers", "Nice",
        "Nîmes", "Niort", "Orléans", "Pau", "Périgueux", "Perpignan", "Poitiers", "Privas", "Quimper", "Reims",
        "Rennes", "Roanne", "Rodez", "Rouen", "Saint-Brieuc", "Saint-Étienne", "Saint-Lô", "Saint-Malo", "Saint-Nazaire", "Sète",
        "Strasbourg", "Tarbes", "Thionville", "Toulon", "Toulouse", "Tourcoing", "Tours", "Troyes", "Tulle", "Valence",
        "Valenciennes", "Vannes", "Verdun", "Versailles", "Vesoul", "Vichy", "Vienne", "Villeurbanne"
    };

    static WndProc proc = Handle;
    static IntPtr combo, list, slider, labelFont, codeFont;
    static string statePath, code, written;

    static IntPtr Control(IntPtr parent, IntPtr inst, string cls, string text, uint style, int x, int y, int w, int h) {
        IntPtr c = CreateWindowExW(0, cls, text, Child | style, x, y, w, h, parent, IntPtr.Zero, inst, IntPtr.Zero);
        Send(c, 0x30, labelFont, (IntPtr)1);
        return c;
    }

    static string Entry(IntPtr control, uint current, uint text, string none) {
        int i = (int)Send(control, current, IntPtr.Zero, IntPtr.Zero);
        if (i < 0) return none;
        StringBuilder s = new StringBuilder(256);
        ReadText(control, text, (IntPtr)i, s);
        return s.ToString();
    }

    static void WriteState() {
        string json = "{\"quality\":\"" + Entry(combo, 0x147, 0x148, "") + "\",\"city\":\"" + Entry(list, 0x188, 0x189, "") +
            "\",\"volume\":" + (int)Send(slider, 0x400, IntPtr.Zero, IntPtr.Zero) + "}";
        if (json == written) return;
        try {
            File.WriteAllText(statePath + ".tmp", json, new UTF8Encoding(false));
            File.Copy(statePath + ".tmp", statePath, true);
            written = json;
        } catch (IOException) { }
    }

    static IntPtr Handle(IntPtr h, uint m, IntPtr w, IntPtr l) {
        switch (m) {
            case 0x113:
                WriteState();
                return IntPtr.Zero;
            case 0xF: {
                PAINTSTRUCT p;
                IntPtr dc = BeginPaint(h, out p);
                IntPtr old = SelectObject(dc, codeFont);
                SetBkMode(dc, 1);
                SetTextColor(dc, 0x00301010);
                RECT r = new RECT();
                r.l = 20; r.t = 330; r.r = 580; r.b = 500;
                DrawTextW(dc, code, code.Length, ref r, 0x25);
                SelectObject(dc, old);
                EndPaint(h, ref p);
                return IntPtr.Zero;
            }
            case 0x2:
                PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return DefWindowProcW(h, m, w, l);
    }

    [STAThread]
    static int Main(string[] args) {
        if (args.Length != 2) return 2;
        statePath = args[0];
        code = args[1];
        SetProcessDpiAwarenessContext((IntPtr)(-4));
        ICC icc = new ICC();
        icc.size = Marshal.SizeOf(typeof(ICC));
        icc.classes = 0x4;
        InitCommonControlsEx(ref icc);
        IntPtr inst = GetModuleHandleW(null);
        WNDCLASSEX c = new WNDCLASSEX();
        c.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
        c.lpfnWndProc = proc;
        c.hInstance = inst;
        c.hCursor = LoadCursorW(IntPtr.Zero, (IntPtr)32512);
        c.hbrBackground = (IntPtr)16;
        c.lpszClassName = "NeoEvalsPanel";
        if (RegisterClassExW(ref c) == 0) return 1;
        labelFont = CreateFontW(-18, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        codeFont = CreateFontW(-150, 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        IntPtr window = CreateWindowExW(0, "NeoEvalsPanel", "Réglages neo-compute", 0x10CF0000 | 0x02000000, 120, 80, 616, 560, IntPtr.Zero, IntPtr.Zero, inst, IntPtr.Zero);
        if (window == IntPtr.Zero) return 1;
        Control(window, inst, "STATIC", "Qualité :", 0, 20, 24, 110, 26);
        combo = Control(window, inst, "COMBOBOX", null, 0x00210003, 140, 20, 260, 220);
        Control(window, inst, "STATIC", "Volume :", 0, 20, 74, 110, 26);
        slider = Control(window, inst, "msctls_trackbar32", "Volume", 0x00010000, 140, 68, 320, 36);
        Control(window, inst, "STATIC", "Ville :", 0, 20, 124, 110, 26);
        list = Control(window, inst, "LISTBOX", null, 0x00A10001, 140, 120, 260, 190);
        foreach (string q in Qualities) SendText(combo, 0x143, IntPtr.Zero, q);
        Send(combo, 0x14E, (IntPtr)1, IntPtr.Zero);
        foreach (string city in Cities) SendText(list, 0x180, IntPtr.Zero, city);
        Send(slider, 0x406, (IntPtr)1, (IntPtr)(100 << 16));
        Send(slider, 0x405, (IntPtr)1, (IntPtr)20);
        WriteState();
        SetTimer(window, (UIntPtr)1, 200, IntPtr.Zero);
        MSG msg;
        while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
        return 0;
    }
}
