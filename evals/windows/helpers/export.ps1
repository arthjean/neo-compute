<#
Window of the dialog-wait task: « Lancer l'export » shows a progress label,
then after DelaySeconds a modal « Export terminé » dialog owned by the
window, whose two buttons write their label to the Result file. Run with
pwsh -STA (WinForms).
#>
param([string]$Result, [int]$DelaySeconds = 8)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Export neo-compute'
$form.ClientSize = New-Object System.Drawing.Size(420, 160)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Prêt à exporter le rapport.'
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(20, 20)
$form.Controls.Add($status)

$start = New-Object System.Windows.Forms.Button
$start.Text = "Lancer l'export"
$start.AutoSize = $true
$start.Location = New-Object System.Drawing.Point(20, 70)
$form.Controls.Add($start)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $DelaySeconds * 1000
$timer.Add_Tick({
        $timer.Stop()
        $status.Text = 'Export terminé.'
        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = 'Export terminé'
        $dialog.ClientSize = New-Object System.Drawing.Size(360, 130)
        $dialog.StartPosition = 'CenterParent'
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MinimizeBox = $false
        $dialog.MaximizeBox = $false
        $dialog.Font = $form.Font
        $label = New-Object System.Windows.Forms.Label
        $label.Text = "Le rapport est prêt. Que faire du fichier exporté ?"
        $label.AutoSize = $true
        $label.Location = New-Object System.Drawing.Point(16, 16)
        $dialog.Controls.Add($label)
        $x = 16
        foreach ($choice in 'Supprimer', 'Conserver') {
            $b = New-Object System.Windows.Forms.Button
            $b.Text = $choice
            $b.AutoSize = $true
            $b.Location = New-Object System.Drawing.Point($x, 70)
            $b.Add_Click({
                    param($s)
                    Set-Content -LiteralPath $Result $s.Text -NoNewline
                    $dialog.Close()
                })
            $dialog.Controls.Add($b)
            $x += 140
        }
        [void]$dialog.ShowDialog($form)
        $form.Text = 'Export neo-compute : terminé'
    })

$start.Add_Click({
        $start.Enabled = $false
        $status.Text = 'Export en cours…'
        $timer.Start()
    })

[void][System.Windows.Forms.Application]::Run($form)
