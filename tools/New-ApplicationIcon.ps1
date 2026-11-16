[CmdletBinding()]
param(
    [string] $MasterDirectory = (Join-Path $PSScriptRoot "..\docs\branding\app-icon"),
    [string] $IconPath = (Join-Path $PSScriptRoot "..\src\FingVibe.App\Assets\Scanner.ico"),
    [string] $PreviewPath = (Join-Path $PSScriptRoot "..\docs\branding\app-icon\connected-home-preview.png")
)

# Renders the Connected home SVG masters into the multi-resolution application icon.
# Each frame size uses the master tuned for it, so small frames are drawn, not downsampled.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$script:IconFrames = @{
    16 = "connected-home-16.svg"
    20 = "connected-home-24.svg"
    24 = "connected-home-24.svg"
    32 = "connected-home-32.svg"
    40 = "connected-home-48.svg"
    48 = "connected-home-48.svg"
    64 = "connected-home.svg"
    256 = "connected-home.svg"
}

function ConvertTo-IconColor([string] $Value) {
    if ($Value -notmatch '^#([0-9A-Fa-f]{6})$') { throw "Unsupported icon color '$Value'." }
    $rgb = [Convert]::ToInt32($Matches[1], 16)
    [System.Drawing.Color]::FromArgb(255, ($rgb -shr 16) -band 255, ($rgb -shr 8) -band 255, $rgb -band 255)
}

function Get-IconNumber($Node, [string] $Name, [double] $Default = 0) {
    $value = $Node.GetAttribute($Name)
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
}

function New-IconRoundedRectangle([double] $X, [double] $Y, [double] $Width, [double] $Height, [double] $Radius) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    if ($Radius -le 0) {
        $path.AddRectangle([System.Drawing.RectangleF]::new($X, $Y, $Width, $Height))
        return $path
    }
    $d = [Math]::Min(2 * $Radius, [Math]::Min($Width, $Height))
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $Width - $d, $Y + $Height - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function Get-IconBrush($Node, [hashtable] $Gradients) {
    $fill = $Node.GetAttribute("fill")
    if (-not $fill -or $fill -eq "none") { return $null }
    if ($fill -match '^url\(#([^)]+)\)$') {
        $gradient = $Gradients[$Matches[1]]
        if (-not $gradient) { throw "Unknown icon gradient '$fill'." }
        return [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            [System.Drawing.PointF]::new($gradient.X1, $gradient.Y1),
            [System.Drawing.PointF]::new($gradient.X2, $gradient.Y2),
            $gradient.From, $gradient.To)
    }
    [System.Drawing.SolidBrush]::new((ConvertTo-IconColor $fill))
}

function Get-IconPen($Node) {
    $stroke = $Node.GetAttribute("stroke")
    if (-not $stroke -or $stroke -eq "none") { return $null }
    $pen = [System.Drawing.Pen]::new((ConvertTo-IconColor $stroke), [float](Get-IconNumber $Node "stroke-width" 1))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen
}

function Read-IconMaster([string] $Path) {
    [xml] $document = Get-Content -LiteralPath $Path -Raw
    $svg = $document.DocumentElement
    $viewBox = @($svg.GetAttribute("viewBox").Split(" ") | ForEach-Object {
        [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
    if ($viewBox.Count -ne 4 -or $viewBox[0] -ne 0 -or $viewBox[1] -ne 0 -or $viewBox[2] -ne $viewBox[3]) {
        throw "Icon master '$Path' must use a square viewBox starting at 0 0."
    }
    $gradients = @{}
    foreach ($gradient in $svg.GetElementsByTagName("linearGradient")) {
        $stops = @($gradient.GetElementsByTagName("stop"))
        $gradients[$gradient.GetAttribute("id")] = @{
            X1 = Get-IconNumber $gradient "x1"; Y1 = Get-IconNumber $gradient "y1"
            X2 = Get-IconNumber $gradient "x2"; Y2 = Get-IconNumber $gradient "y2"
            From = ConvertTo-IconColor $stops[0].GetAttribute("stop-color")
            To = ConvertTo-IconColor $stops[-1].GetAttribute("stop-color")
        }
    }
    $shapes = @($svg.ChildNodes | Where-Object { $_.NodeType -eq "Element" -and $_.LocalName -notin @("title", "desc", "defs") })
    @{ Size = $viewBox[2]; Gradients = $gradients; Shapes = $shapes }
}

function Invoke-IconShape($Graphics, $Node, [hashtable] $Gradients) {
    $brush = Get-IconBrush $Node $Gradients
    $pen = Get-IconPen $Node
    try {
        switch ($Node.LocalName) {
            "rect" {
                $path = New-IconRoundedRectangle (Get-IconNumber $Node "x") (Get-IconNumber $Node "y") `
                    (Get-IconNumber $Node "width") (Get-IconNumber $Node "height") (Get-IconNumber $Node "rx")
                if ($brush) { $Graphics.FillPath($brush, $path) }
                if ($pen) { $Graphics.DrawPath($pen, $path) }
                $path.Dispose()
            }
            "circle" {
                $r = Get-IconNumber $Node "r"
                $x = (Get-IconNumber $Node "cx") - $r
                $y = (Get-IconNumber $Node "cy") - $r
                if ($brush) { $Graphics.FillEllipse($brush, [float]$x, [float]$y, [float](2 * $r), [float](2 * $r)) }
                if ($pen) { $Graphics.DrawEllipse($pen, [float]$x, [float]$y, [float](2 * $r), [float](2 * $r)) }
            }
            "polyline" {
                $values = @($Node.GetAttribute("points") -split '[ ,]+' | Where-Object { $_ } | ForEach-Object {
                    [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
                $points = for ($i = 0; $i -lt $values.Count; $i += 2) { [System.Drawing.PointF]::new($values[$i], $values[$i + 1]) }
                if (-not $pen) { throw "Icon polylines must be stroked." }
                $Graphics.DrawLines($pen, [System.Drawing.PointF[]]$points)
            }
            "path" {
                # Supports a single circular arc: M x1 y1 A r r 0 large sweep x2 y2.
                $d = $Node.GetAttribute("d")
                $number = '(-?[0-9.]+)'
                if ($d -notmatch "^M $number $number A $number $number 0 ([01]) ([01]) $number $number$") {
                    throw "Unsupported icon path '$d'."
                }
                $v = @($Matches[1..8] | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
                $x1, $y1, $r, $large, $sweep, $x2, $y2 = $v[0], $v[1], $v[2], $v[4], $v[5], $v[6], $v[7]
                $mx = ($x1 + $x2) / 2; $my = ($y1 + $y2) / 2
                $dx = $x2 - $x1; $dy = $y2 - $y1
                $half = [Math]::Sqrt($dx * $dx + $dy * $dy) / 2
                $offset = [Math]::Sqrt([Math]::Max(0, $r * $r - $half * $half))
                $sign = if ($large -eq $sweep) { -1 } else { 1 }
                $cx = $mx - $sign * $offset * $dy / (2 * $half)
                $cy = $my + $sign * $offset * $dx / (2 * $half)
                $start = [Math]::Atan2($y1 - $cy, $x1 - $cx) * 180 / [Math]::PI
                $end = [Math]::Atan2($y2 - $cy, $x2 - $cx) * 180 / [Math]::PI
                $span = if ($sweep -eq 1) { ($end - $start + 360) % 360 } else { -(($start - $end + 360) % 360) }
                if (-not $pen) { throw "Icon arcs must be stroked." }
                $Graphics.DrawArc($pen, [float]($cx - $r), [float]($cy - $r), [float](2 * $r), [float](2 * $r), [float]$start, [float]$span)
            }
            default { throw "Unsupported icon element '$($Node.LocalName)'." }
        }
    }
    finally {
        if ($brush) { $brush.Dispose() }
        if ($pen) { $pen.Dispose() }
    }
}

function New-IconFrame([hashtable] $Master, [int] $Size) {
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.ScaleTransform([float]($Size / $Master.Size), [float]($Size / $Master.Size))
        foreach ($shape in $Master.Shapes) { Invoke-IconShape $graphics $shape $Master.Gradients }
    }
    finally { $graphics.Dispose() }
    $bitmap
}

function Get-IconFrameBytes([System.Drawing.Bitmap] $Bitmap) {
    $size = $Bitmap.Width
    if ($size -ge 256) {
        $stream = [IO.MemoryStream]::new()
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    $rect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $pixels = [byte[]]::new($data.Stride * $size)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    }
    finally { $Bitmap.UnlockBits($data) }
    $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint32]40); $writer.Write([int32]$size); $writer.Write([int32]($size * 2))
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]0)
    $writer.Write([uint32]($size * $size * 4 + $maskStride * $size))
    $writer.Write([int32]0); $writer.Write([int32]0); $writer.Write([uint32]0); $writer.Write([uint32]0)
    for ($y = $size - 1; $y -ge 0; $y--) { $writer.Write($pixels, $y * $data.Stride, $size * 4) }
    for ($y = $size - 1; $y -ge 0; $y--) {
        $row = [byte[]]::new($maskStride)
        for ($x = 0; $x -lt $size; $x++) {
            if ($pixels[$y * $data.Stride + $x * 4 + 3] -eq 0) { $row[[Math]::Floor($x / 8)] = $row[[Math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8)) }
        }
        $writer.Write($row)
    }
    $writer.Flush()
    $stream.ToArray()
}

function Write-ApplicationIcon([hashtable] $Frames, [string] $Path) {
    $sizes = @($Frames.Keys | Sort-Object)
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($size in $sizes) {
        $bytes = $Frames[$size]
        $dimension = if ($size -ge 256) { 0 } else { $size }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$bytes.Length); $writer.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($size in $sizes) { $writer.Write([byte[]]$Frames[$size]) }
    $writer.Flush()
    [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Path), $stream.ToArray())
}

function Save-IconPreview([hashtable] $Bitmaps, [string] $Path) {
    $sizes = @($Bitmaps.Keys | Sort-Object)
    $magnified = @($sizes | Where-Object { $_ -le 64 })
    $gap = 16
    $actualWidth = ($sizes | Measure-Object -Sum).Sum + $gap * ($sizes.Count + 1)
    $zoomWidth = (($magnified | ForEach-Object { $_ * 4 }) | Measure-Object -Sum).Sum + $gap * ($magnified.Count + 1)
    $panelWidth = [int][Math]::Max($actualWidth, $zoomWidth)
    $actualHeight = 256 + 2 * $gap
    $zoomHeight = 64 * 4 + 2 * $gap
    $preview = [System.Drawing.Bitmap]::new([int]($panelWidth * 2), [int]($actualHeight + $zoomHeight))
    $graphics = [System.Drawing.Graphics]::FromImage($preview)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $backgrounds = @([System.Drawing.Color]::FromArgb(243, 243, 243), [System.Drawing.Color]::FromArgb(32, 32, 32))
        for ($panel = 0; $panel -lt 2; $panel++) {
            $left = $panel * $panelWidth
            $brush = [System.Drawing.SolidBrush]::new($backgrounds[$panel])
            $graphics.FillRectangle($brush, $left, 0, $panelWidth, $preview.Height)
            $brush.Dispose()
            $x = $left + $gap
            foreach ($size in $sizes) {
                $graphics.DrawImage($Bitmaps[$size], $x, $gap + 256 - $size, $size, $size)
                $x += $size + $gap
            }
            $x = $left + $gap
            foreach ($size in $magnified) {
                $graphics.DrawImage($Bitmaps[$size], $x, $actualHeight + $gap + 256 - $size * 4, $size * 4, $size * 4)
                $x += $size * 4 + $gap
            }
        }
    }
    finally { $graphics.Dispose() }
    $preview.Save([IO.Path]::GetFullPath($Path), [System.Drawing.Imaging.ImageFormat]::Png)
    $preview.Dispose()
}

$masters = @{}
$bitmaps = @{}
$frames = @{}
try {
    foreach ($size in @($script:IconFrames.Keys | Sort-Object)) {
        $name = $script:IconFrames[$size]
        if (-not $masters.ContainsKey($name)) { $masters[$name] = Read-IconMaster (Join-Path $MasterDirectory $name) }
        $bitmaps[$size] = New-IconFrame $masters[$name] $size
        $frames[$size] = Get-IconFrameBytes $bitmaps[$size]
    }
    Write-ApplicationIcon $frames $IconPath
    if ($PreviewPath) { Save-IconPreview $bitmaps $PreviewPath }
}
finally { foreach ($bitmap in $bitmaps.Values) { $bitmap.Dispose() } }
Write-Host "Wrote $($frames.Count) icon frames to $([IO.Path]::GetFullPath($IconPath))."
