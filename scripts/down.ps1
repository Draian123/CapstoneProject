<#
.SYNOPSIS
  PowerShell wrapper around scripts/down.sh.

.DESCRIPTION
  The lifecycle scripts are written in Bash so the same file runs locally and
  in GitHub Actions. Git for Windows ships Bash, so this wrapper just forwards
  to it and preserves the exit code.

.EXAMPLE
  .\scripts${s}.ps1 dev
#>
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $scriptDir 'down.sh'

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    $fallback = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (Test-Path $fallback) {
        $bash = $fallback
    } else {
        throw "bash was not found. Install Git for Windows, or run scripts/down.sh from Git Bash or WSL."
    }
}

& $bash $target @Args
exit $LASTEXITCODE
