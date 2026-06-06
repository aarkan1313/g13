# WG13 launcher — runs the project windowed (Vulkan) on the interactive desktop
# so you can fly the world without opening the Godot editor. The agent runs this.
#
#   .\run.ps1            # launch the demo scene (fly: WASD + right-drag, Shift boost)
#   .\run.ps1 -Stop      # close any running launched instance
#
# Requires Vulkan (GPU field needs a real RenderingDevice; --headless won't work).
#
# WHY a background Job and not Start-Process: Start-Process / bash '&' return a
# detached stub PID, so the real Godot can't be tracked and (in this sandbox)
# the window didn't reliably surface. A PS Job keeps it in session 1 (the
# interactive console) and a visible window appears. (See DRIFT_LOG 2026-06-06.)

param([switch]$Stop)

$godot = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64.exe"
$proj  = "D:\world gen 13\wg-13"

if ($Stop) {
    Get-Process -Name "Godot*" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Job -Name wg13run -ErrorAction SilentlyContinue | Remove-Job -Force
    "stopped"
    return
}

# Don't stack instances.
Get-Process -Name "Godot*" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Job -Name wg13run -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

Start-Job -Name wg13run -ScriptBlock {
    & $using:godot --rendering-driver vulkan --path $using:proj
} | Out-Null

Start-Sleep -Seconds 5
$g = Get-Process -Name "Godot*" -ErrorAction SilentlyContinue
if ($g -and $g.MainWindowHandle -ne 0) {
    "launched: pid $($g.Id), window '$($g.MainWindowTitle)' on session $($g.SessionId)"
} else {
    "launch issued; window may still be initializing"
}
