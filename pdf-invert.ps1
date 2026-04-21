param(
    $fileName
)

# Requires ghost script to be installed!
# https://ghostscript.com/releases/gsdnld.html

$gsExe = "C:\Program Files\gs\gs10.05.0\bin\gswin64c.exe"
$resolvedInput = (Resolve-Path $fileName).Path
$output = (Split-Path $resolvedInput -LeafBase) + "-out.pdf"

# Step 1: Render first page at moderate resolution to detect background color
$tempPng = Join-Path ([System.IO.Path]::GetTempPath()) "pdf-invert-bg-detect.png"
& $gsExe -q -dBATCH -dNOPAUSE -dFirstPage=1 -dLastPage=1 -sDEVICE=png16m -r30 -o $tempPng $resolvedInput

if (-not (Test-Path $tempPng)) {
    Write-Error "Failed to render PDF for background detection."
    exit 1
}

# Step 2: Detect background color by finding the most common color in the page.
# Using the modal (most frequent) color is robust: the background dominates the
# page by area, even if the true edge of the page happens to be blank/white.
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::FromFile($tempPng)

# Lock bits for fast pixel access
$imgW = $img.Width
$imgH = $img.Height
$rect = [System.Drawing.Rectangle]::new(0, 0, $imgW, $imgH)
$bmpData = $img.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$stride = $bmpData.Stride
$byteCount = $stride * $imgH
$bytes = [byte[]]::new($byteCount)
[System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $bytes, 0, $byteCount)
$img.UnlockBits($bmpData)

# Count colors, quantized to 8-level buckets per channel to merge anti-aliased variants
$counts = @{}
for ($y = 0; $y -lt $imgH; $y++) {
    $row = $y * $stride
    for ($x = 0; $x -lt $imgW; $x++) {
        $i = $row + $x * 3
        # Format24bppRgb stores as BGR
        $b = $bytes[$i]
        $g = $bytes[$i + 1]
        $r = $bytes[$i + 2]
        $key = ([int]($r -shr 3) -shl 16) -bor ([int]($g -shr 3) -shl 8) -bor [int]($b -shr 3)
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
    }
}
$img.Dispose()
Remove-Item $tempPng -ErrorAction SilentlyContinue

$topEntry = $counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
$topKey = [int]$topEntry.Key
# Reconstruct the quantized center (shift back and add half-bucket)
$bgRi = (($topKey -shr 16) -band 0x1F) * 8 + 4
$bgGi = (($topKey -shr 8) -band 0x1F) * 8 + 4
$bgBi = ($topKey -band 0x1F) * 8 + 4

$bgR = $bgRi / 255.0
$bgG = $bgGi / 255.0
$bgB = $bgBi / 255.0

Write-Host "Detected background color: RGB($bgRi, $bgGi, $bgBi) from $($topEntry.Value) / $($imgW * $imgH) pixels"

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