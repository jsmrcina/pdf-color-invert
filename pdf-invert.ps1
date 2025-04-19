param(
    $fileName
)

# Requires ghost script to be installed!
# https://ghostscript.com/releases/gsdnld.html

$input = $fileName
$output = (Split-Path $fileName -LeafBase) + "-out.pdf"
& "C:\Program Files\gs\gs10.05.0\bin\gswin64.exe" -o $output -sDEVICE=pdfwrite -c "{1 exch sub}{1 exch sub}{1 exch sub}{1 exch sub} setcolortransfer" -f $input