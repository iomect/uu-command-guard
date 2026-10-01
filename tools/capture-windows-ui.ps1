param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PreviewWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
}
'@
$process = Start-Process -FilePath (Resolve-Path $Executable) -ArgumentList '--ui-preview' -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw 'UI preview exited before showing its window' }
        $handle = $process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($handle -eq [IntPtr]::Zero) { throw 'UI preview did not show a window' }
    $class = [Text.StringBuilder]::new(256)
    [void][PreviewWindow]::GetClassName($handle, $class, $class.Capacity)
    if ($class.ToString() -ne 'UUBridgeSettings') { throw "Unexpected preview window: $class" }
    $rect = [PreviewWindow+Rect]::new()
    if (-not [PreviewWindow]::GetWindowRect($handle, [ref]$rect)) { throw 'Cannot read preview window size' }
    $bitmap = [Drawing.Bitmap]::new($rect.Right-$rect.Left, $rect.Bottom-$rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try {
            if (-not [PreviewWindow]::PrintWindow($handle, $dc, 2)) { throw 'Cannot capture preview window' }
        } finally { $graphics.ReleaseHdc($dc) }
        $output_path = [IO.Path]::GetFullPath($Output)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output_path))
        $bitmap.Save($output_path, [Drawing.Imaging.ImageFormat]::Png)
        Write-Output "Captured Windows UI: $($bitmap.Width)x$($bitmap.Height)"
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(10000)) { throw 'UI preview did not exit cleanly' }
    if ($process.ExitCode -ne 0) { throw "UI preview failed: $($process.ExitCode)" }
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
