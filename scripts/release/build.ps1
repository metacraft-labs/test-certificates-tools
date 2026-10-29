# Release build for one Windows target, run by the shared release workflow
# after setup-windows.ps1 has provided the pinned compiler:
# `./scripts/release/build.ps1 -Target windows-x86_64`.
param([Parameter(Mandatory = $true)][string]$Target)
. "$env:RELEASE_TOOLS/common.ps1"
Invoke-ReleaseNim 'src/test_certificates_cli.nim' "$ReleaseStage/bin/test-certificates.exe"
Copy-Item LICENSE, NOTICE $ReleaseStage
Complete-Release
