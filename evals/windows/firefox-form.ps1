param([ValidateSet('available', 'setup', 'solve', 'verify', 'cleanup')][string]$Phase, [string]$Work)
. "$PSScriptRoot/lib.ps1"
# US-025: the form of chrome-form, in Firefox on a fresh profile. On a
# machine without Firefox the task is skipped, not failed.

switch ($Phase) {
    'available' {
        if (-not (Test-Path $firefoxExe)) { return "Firefox absent ($firefoxExe)" }
        $null
    }
    'setup' { Start-FirefoxPage $Work 'form.html' 'Formulaire neo-compute' }
    'solve' {
        # Keyboard from the name field: typing S selects Suisse in the closed
        # list, the checkbox stays unchecked, Enter on the button submits.
        $w = Find-Window 'Formulaire neo-compute*'
        Show-Window $w
        $deadline = (Get-Date).AddSeconds(15)
        do {
            $c = [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit),
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Nom'))
            $field = (Get-UiaRoot $w).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
            if (-not $field) { Start-Sleep -Milliseconds 500 }
        } while (-not $field -and (Get-Date) -lt $deadline)
        if (-not $field) { throw 'champ Nom introuvable dans Firefox' }
        $field.SetFocus()
        Send-Keys 'Grace Hopper'
        Send-Keys '{TAB}'
        Send-Keys 'S'
        Send-Keys '{TAB}{TAB}'
        Send-Keys '{ENTER}'
        Start-Sleep -Seconds 1
    }
    'verify' {
        $want = 'envoyé nom=Grace Hopper;pays=Suisse;abonne=non'
        $sent = Find-Window 'envoyé nom=*'
        if (-not $sent) { return New-Result $false 'formulaire non envoyé' }
        New-Result ($sent.Value -like "$want*") "titre : $($sent.Value)"
    }
    'cleanup' { Stop-FirefoxProfile $Work }
}
