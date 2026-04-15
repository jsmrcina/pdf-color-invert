param(
    $fileName
)

# Requires ghost script to be installed!
# https://ghostscript.com/releases/gsdnld.html

$gsExe = "C:\Program Files\gs\gs10.05.0\bin\gswin64c.exe"
$resolvedInput = (Resolve-Path $fileName).Path
$output = (Split-Path $resolvedInput -LeafBase) + "-out.pdf"

# Step 1: Render first page at low resolution to detect background color
$tempPng = Join-Path ([System.IO.Path]::GetTempPath()) "pdf-invert-bg-detect.png"
& $gsExe -q -dBATCH -dNOPAUSE -dFirstPage=1 -dLastPage=1 -sDEVICE=png16m -r10 -o $tempPng $resolvedInput

if (-not (Test-Path $tempPng)) {
    Write-Error "Failed to render PDF for background detection."
    exit 1
}

# Step 2: Read background color from top-left corner pixel
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::FromFile($tempPng)
$bgColor = $img.GetPixel(0, 0)
$img.Dispose()
Remove-Item $tempPng -ErrorAction SilentlyContinue

$bgR = $bgColor.R / 255.0
$bgG = $bgColor.G / 255.0
$bgB = $bgColor.B / 255.0

Write-Host "Detected background color: RGB($($bgColor.R), $($bgColor.G), $($bgColor.B))"

# Step 3: Build per-channel transfer functions
# For each RGB channel with background value b:
#   f(x) = min(1, (1 - x) / (1 - b))
# This maps the background value -> 1.0 (white) and inverts everything else.
function Get-TransferFunc($bgVal) {
    $denom = [Math]::Round(1.0 - $bgVal, 6)
    if ($denom -lt 0.01) {
        # Background channel is already near-white; leave unchanged
        return "{ }"
    }
    return "{ 1 exch sub $denom div dup 1 gt { pop 1 } if }"
}

$rFunc = Get-TransferFunc $bgR
$gFunc = Get-TransferFunc $bgG
$bFunc = Get-TransferFunc $bgB

# Gray channel uses luminance-weighted background value
$bgGray = 0.299 * $bgR + 0.587 * $bgG + 0.114 * $bgB
$grayFunc = Get-TransferFunc $bgGray

$psCmd = "$rFunc $gFunc $bFunc $grayFunc setcolortransfer"

# Step 4: Apply the color transform
Write-Host "Applying color transform..."
& $gsExe -o $output -sDEVICE=pdfwrite -c $psCmd -f $resolvedInput
Write-Host "Output: $output"