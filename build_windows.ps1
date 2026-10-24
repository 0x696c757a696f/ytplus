$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error 'Flutter SDK not found in PATH. Install Flutter and Visual Studio Desktop C++ tools first.'
}
flutter doctor -v
if ($LASTEXITCODE -ne 0) { throw 'flutter doctor failed' }
flutter create --platforms=windows --project-name lumtub .
if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
Write-Host 'Build successful. Check build/windows/x64/runner/Release.' -ForegroundColor Green
