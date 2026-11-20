// The WinForms window of `bg-select-winforms` (US-064), compiled by the
// selftest with the .NET Framework compiler. A WinForms combo box is a
// superclass of the Win32 ComboBox: its form reflects the WM_COMMAND it
// receives back to the control, which raises SelectedIndexChanged. The title
// shows what the control raised: "neo-compute winforms <changes> <drop-downs>
// <selected index>".
using System;
using System.Drawing;
using System.Windows.Forms;

static class Program {
    [STAThread]
    static void Main(string[] args) {
        Application.EnableVisualStyles();
        Application.Run(new Probe(int.Parse(args[0]), int.Parse(args[1])));
    }
}

class Probe : Form {
    int changes, dropdowns;
    readonly ComboBox combo;

    // Shown under the decoy: never active.
    protected override bool ShowWithoutActivation { get { return true; } }

    public Probe(int x, int y) {
        StartPosition = FormStartPosition.Manual;
        Location = new Point(x, y);
        Size = new Size(360, 160);
        combo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(20, 20), Width = 260 };
        combo.Items.AddRange(new object[] { "neo-compute winforms A", "neo-compute winforms B", "neo-compute winforms C" });
        combo.SelectedIndex = 0;
        combo.SelectedIndexChanged += (s, e) => { changes++; Report(); };
        combo.DropDown += (s, e) => { dropdowns++; Report(); };
        Controls.Add(combo);
        Report();
    }

    void Report() {
        Text = "neo-compute winforms " + changes + " " + dropdowns + " " + combo.SelectedIndex;
    }
}
