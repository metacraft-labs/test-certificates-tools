# The test suite on Windows, where there is no Nix dev shell: the equivalent
# of `just test`. It expects nim (2.2), a MinGW-w64 gcc and Git for Windows on
# PATH, and the specification checkout beside this one or in -SpecDir (as
# `just test` does). Run from anywhere:
#
#   pwsh -File scripts/windows/test.ps1 [-SpecDir <test-certificates-spec>]
#
# Each tests/t_*.nim is compiled and run; a missing prerequisite or any
# failing file fails the script. Cases that cannot apply to Windows are
# compiled out inside their files, each with the reason beside it.
param([string]$SpecDir = "")

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')

foreach ($tool in 'nim', 'gcc', 'git') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on PATH; this script needs nim 2.2, a MinGW-w64 gcc and Git for Windows"
  }
}
# Git for Windows' usr\bin goes FIRST on PATH: the signing fixtures run
# ssh-keygen, and the hook tests use `sleep` behind git's ext:: transport.
# Windows' own OpenSSH ssh-keygen (C:\Program Files\OpenSSH, usually earlier
# on PATH) cannot be used: with its standard streams on pipes it prints its
# answer and never exits (measured on Windows 11 25H2, with Nim's
# osproc.startProcess as well as with this package's runProcess).
$gitRoot = Split-Path (Split-Path (Get-Command git).Source)
$usrBin = Join-Path $gitRoot 'usr\bin'
foreach ($tool in 'ssh-keygen.exe', 'sleep.exe') {
  if (-not (Test-Path (Join-Path $usrBin $tool))) { throw "$tool is not in $usrBin (Git for Windows)" }
}
$env:PATH = "$usrBin;$env:PATH"
& nim -v | Select-Object -First 1
& gcc --version | Select-Object -First 1
& git --version

if ($SpecDir) { $env:TEST_CERTIFICATES_SPEC_DIR = (Resolve-Path $SpecDir).Path }

New-Item -ItemType Directory -Force build\bin, build\tests | Out-Null
& nim c -d:release --hints:off -o:build\bin\test-certificates.exe src\test_certificates_cli.nim
if ($LASTEXITCODE -ne 0) { throw "building test-certificates.exe failed" }
$env:TEST_CERTIFICATES_BIN = (Resolve-Path build\bin\test-certificates.exe).Path

$failed = @()
foreach ($t in Get-ChildItem tests -Filter 't_*.nim' | Sort-Object Name) {
  $name = $t.BaseName
  Write-Host "=== $name"
  & nim c --hints:off "-o:build\tests\$name.exe" $t.FullName
  if ($LASTEXITCODE -ne 0) { $failed += "$name (compile)"; continue }
  & "build\tests\$name.exe"
  if ($LASTEXITCODE -ne 0) { $failed += $name }
}
if ($failed.Count -gt 0) { throw "FAILED: $($failed -join ', ')" }
Write-Host "all test files passed"
