# Builds Neev Remote for Windows (x64). Both outputs are SELF-CONTAINED — they
# bundle the Flutter engine, plugin DLLs and the Visual C++ runtime, so end
# users just install/run with nothing pre-installed:
#   dist\NeevRemote-windows-x64-portable.zip  (portable, unzip & run neev_remote.exe)
#   dist\NeevRemote-Setup-x64.exe             (installer, if Inno Setup is installed)
#
# These BUILD-TIME tools are needed only on the machine that builds (not by end
# users): Flutter, Visual Studio "Desktop development with C++", and (for the
# installer) Inno Setup.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$Out = "dist"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host "==> flutter build windows --release"
if ($env:RELAY_URL) {
  flutter build windows --release "--dart-define=RELAY_URL=$($env:RELAY_URL)"
} else {
  flutter build windows --release
}
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed (exit $LASTEXITCODE)" }

$ReleaseDir = "build\windows\x64\runner\Release"
if (-not (Test-Path $ReleaseDir)) { throw "Release dir not found: $ReleaseDir" }
if (-not (Test-Path "$ReleaseDir\neev_remote.exe")) {
  throw "neev_remote.exe missing - build did not produce the app"
}

# Bundle the Visual C++ runtime DLLs next to the exe so the app runs on a clean
# PC with nothing pre-installed (end users don't need the VC++ redistributable).
Write-Host "==> bundling Visual C++ runtime"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  $vsPath = & $vswhere -latest -property installationPath
  $crt = Get-ChildItem (Join-Path $vsPath "VC\Redist\MSVC") -Recurse -Directory `
           -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match "\\x64\\" } |
         Sort-Object FullName -Descending | Select-Object -First 1
  if ($crt) {
    foreach ($dll in "msvcp140.dll","vcruntime140.dll","vcruntime140_1.dll") {
      $src = Join-Path $crt.FullName $dll
      if (Test-Path $src) { Copy-Item $src $ReleaseDir -Force }
    }
    Write-Host "    bundled CRT from $($crt.FullName)"
  } else {
    Write-Warning "    VC++ CRT folder not found; app may need the VC++ redistributable"
  }
} else {
  Write-Warning "    vswhere not found; skipping VC++ runtime bundling"
}

# Build the privileged UAC helper (neev_helper.exe) and drop it next to the app.
# Fully ISOLATED + NON-FATAL: a failure here only means the helper is absent;
# the app itself is unaffected and still ships.
Write-Host "==> building privileged helper (neev_helper.exe)"
try {
  $helperSrc = "windows\service\neev_helper.cpp"
  if ((Test-Path $vswhere) -and (Test-Path $helperSrc)) {
    $vsPath = & $vswhere -latest -property installationPath
    $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    $outExe = Join-Path $ReleaseDir "neev_helper.exe"
    if (Test-Path $vcvars) {
      $bat = @"
call "$vcvars"
cl /nologo /EHsc /O2 /DUNICODE /D_UNICODE "$helperSrc" /Fe:"$outExe" /Fo:"$env:TEMP\neev_helper.obj" /link advapi32.lib user32.lib gdi32.lib gdiplus.lib ole32.lib wtsapi32.lib userenv.lib ws2_32.lib
"@
      $batFile = Join-Path $env:TEMP "build_neev_helper.bat"
      Set-Content -Path $batFile -Value $bat -Encoding Ascii
      cmd /c "`"$batFile`""
      if (Test-Path $outExe) {
        Write-Host "    built $outExe"
      } else {
        Write-Warning "    neev_helper.exe not produced; UAC helper absent (app unaffected)"
      }
    } else {
      Write-Warning "    vcvars64.bat not found; skipping helper build"
    }
  } else {
    Write-Warning "    vswhere or helper source missing; skipping helper build"
  }
} catch {
  Write-Warning "    helper build failed: $_ (app unaffected)"
}

Write-Host "==> portable zip"
$Zip = Join-Path $Out "NeevRemote-windows-x64-portable.zip"
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $Zip

Write-Host "==> installer (Inno Setup)"
$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
if ($iscc) {
  & $iscc.Source "packaging\windows\installer.iss"
  Write-Host "Installer written to $Out"
} else {
  Write-Warning "iscc.exe not found - skipping installer. Install Inno Setup from https://jrsoftware.org/isdl.php"
}

Write-Host "==> done"
Get-ChildItem $Out
