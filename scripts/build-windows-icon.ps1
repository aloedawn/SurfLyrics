[CmdletBinding()]
param([string]$PreviewPath='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$taskRoot=Split-Path $PSScriptRoot -Parent
function Convert-IconPath([string]$data) {
 $path=[Drawing.Drawing2D.GraphicsPath]::new()
 $tokens=[regex]::Matches($data,'[MCLZHV]|[-+]?(?:\d*\.\d+|\d+\.?\d*)')
 $index=0; $command=''; $x=0; $y=0; $startX=0; $startY=0
 while($index -lt $tokens.Count) {
  if($tokens[$index].Value -match '^[MCLZHV]$') {$command=$tokens[$index].Value; $index++}
  if($command -eq 'Z') {$path.CloseFigure();$x=$startX;$y=$startY;$command='';continue}
  $count=switch($command){'M'{2};'L'{2};'C'{6};'H'{1};'V'{1};default{throw 'Unsupported icon SVG command.'}}
  $v=[Collections.Generic.List[single]]::new()
  for($n=0;$n -lt $count;$n++) {
   $v.Add([single]::Parse($tokens[$index].Value,[Globalization.CultureInfo]::InvariantCulture))
   $index++
  }
  switch($command) {
   'M' {$x=$v[0];$y=$v[1];$startX=$x;$startY=$y;$path.StartFigure();$command='L'}
   'L' {$path.AddLine([single]$x,[single]$y,$v[0],$v[1]);$x=$v[0];$y=$v[1]}
   'H' {
    $path.AddLine([single]$x,[single]$y,$v[0],[single]$y);$x=$v[0]
   }
   'V' {
    $path.AddLine([single]$x,[single]$y,[single]$x,$v[0]);$y=$v[0]
   }
   'C' {$path.AddBezier([single]$x,[single]$y,$v[0],$v[1],$v[2],$v[3],$v[4],$v[5]);$x=$v[4];$y=$v[5]}
  }
 }
 return $path
}
$taskBackground=[Drawing.Drawing2D.GraphicsPath]::new()
foreach($arc in @(@(24,24,448,448,180),@(552,24,448,448,270),@(552,552,448,448,0),@(24,552,448,448,90))) {
 $taskBackground.AddArc([single]$arc[0],[single]$arc[1],[single]$arc[2],[single]$arc[3],[single]$arc[4],[single]90)
}
$taskBackground.CloseFigure()
$taskPaths=@();$taskBrushes=@()
foreach($taskName in @('Ocean','Melody')){
 $taskSvg=[xml][IO.File]::ReadAllText((Join-Path $taskRoot "SurfLyrics/AppIcon.icon/Assets/$taskName.svg"))
 $taskPaths+=Convert-IconPath $taskSvg.svg.path.d
 $taskBrushes+=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($taskSvg.svg.path.fill))
}
$taskMaster=[Drawing.Bitmap]::new(1024,1024,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
$taskGraphics=[Drawing.Graphics]::FromImage($taskMaster)
$taskGraphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
$taskGradient=[Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.RectangleF]::new(0,0,1024,1024),[Drawing.Color]::FromArgb(16,163,153),[Drawing.Color]::FromArgb(6,110,118),[Drawing.Drawing2D.LinearGradientMode]::Vertical)
$taskGraphics.FillPath($taskGradient,$taskBackground)
for($taskIndex=0;$taskIndex -lt $taskPaths.Count;$taskIndex++){$taskGraphics.FillPath($taskBrushes[$taskIndex],$taskPaths[$taskIndex])}
$taskGraphics.Dispose()
$taskFrames=@()
foreach($taskSize in @(16,20,24,32,40,48,64,128,256)){
 $taskBitmap=[Drawing.Bitmap]::new($taskSize,$taskSize,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
 $taskResize=[Drawing.Graphics]::FromImage($taskBitmap)
 $taskResize.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy
 $taskResize.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
 $taskResize.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
 $taskResize.DrawImage($taskMaster,[Drawing.Rectangle]::new(0,0,$taskSize,$taskSize))
 $taskResize.Dispose()
 $taskStream=[IO.MemoryStream]::new(); $taskBitmap.Save($taskStream,[Drawing.Imaging.ImageFormat]::Png)
 $taskFrames+= [PSCustomObject]@{Size=$taskSize;Bytes=$taskStream.ToArray()}
 if($taskSize -eq 256 -and $PreviewPath){$taskBitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)}
 $taskBitmap.Dispose();$taskStream.Dispose()
}
$taskOutput=Join-Path $taskRoot 'windows/SurfLyrics.Windows/Assets/SurfLyrics.ico'
$taskFile=[IO.File]::Create($taskOutput)
$taskWriter=[IO.BinaryWriter]::new($taskFile)
try {
 $taskWriter.Write([UInt16]0);$taskWriter.Write([UInt16]1);$taskWriter.Write([UInt16]$taskFrames.Count)
 $taskOffset=6+16*$taskFrames.Count
 foreach($taskFrame in $taskFrames){
  $taskDimension=if($taskFrame.Size -eq 256){0}else{$taskFrame.Size}
  $taskWriter.Write([byte]$taskDimension);$taskWriter.Write([byte]$taskDimension)
  $taskWriter.Write([byte]0);$taskWriter.Write([byte]0)
  $taskWriter.Write([UInt16]1);$taskWriter.Write([UInt16]32)
  $taskWriter.Write([UInt32]$taskFrame.Bytes.Length);$taskWriter.Write([UInt32]$taskOffset)
  $taskOffset+=$taskFrame.Bytes.Length
 }
 foreach($taskFrame in $taskFrames){$taskWriter.Write([byte[]]$taskFrame.Bytes)}
} finally {
 $taskWriter.Dispose();$taskMaster.Dispose();$taskGradient.Dispose();$taskBackground.Dispose()
 foreach($taskItem in $taskPaths+$taskBrushes){$taskItem.Dispose()}
}
[PSCustomObject]@{Path=$taskOutput;Sizes=$taskFrames.Size;Bytes=(Get-Item -LiteralPath $taskOutput).Length}