#requires -version 5.1
<#
.SYNOPSIS
  HP Victus RTX 5060 PCF 115 W unlock utility.

.DESCRIPTION
  Proven working values from this machine:
      Stock PCF:
        AC Target TPP      = 125 W
        AC Default GPU     =  90 W
        AC Min GPU         =  80 W
        AC Max GPU         = 100 W

      Unlock:
        AC Target TPP      = 150 W
        AC Max GPU         = 115 W

  Modes:
      Apply  - establish HP Maximum GPU state, then set PCF 150 W / 115 W.
      Status - read current PCF values and NVIDIA enforced power limit.
      Stock  - restore PCF TargetTPP=125 W and ACMaxGPULimit=100 W.

  Apply intentionally never commands ACMaxGPULimit above 115 W, which is the
  maximum reported by this RTX 5060 through nvidia-smi.

  Requires:
      - Administrator PowerShell
      - .NET 8+ SDK
      - Internet only for the first NuGet restore/build
#>

[CmdletBinding()]
param(
    [ValidateSet("Apply","Status","Stock")]
    [string]$Mode = "Apply",

    [ValidateRange(125,180)]
    [int]$PlatformTargetW = 150,

    [ValidateRange(100,115)]
    [int]$GpuMaxW = 115,

    [string]$PackageVersion = "1.1.24-pre.38",

    [int]$WmiTimeoutSec = 8
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$StockTargetW = 125
$StockGpuMaxW = 100

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 76) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 76) -ForegroundColor Cyan
}

function Send-HpBiosWmi {
    param(
        [Parameter(Mandatory=$true)][UInt32]$CommandType,
        [Byte[]]$Data = $null,
        [ValidateSet(0,4,128,1024,4096)][int]$OutputSize = 0,
        [UInt32]$Command = 0x20008
    )

    if ($null -eq $Data) {
        [UInt32]$dataSize = 0
    }
    else {
        [UInt32]$dataSize = $Data.Length
    }

    $props = @{
        Command     = $Command
        CommandType = $CommandType
        Size        = $dataSize
        Sign        = [Byte[]]@(0x53,0x45,0x43,0x55)
    }

    if ($null -ne $Data) {
        $props["hpqBData"] = $Data
    }

    $inData = New-CimInstance `
        -ClassName "hpqBDataIn" `
        -Namespace "root\wmi" `
        -ClientOnly `
        -Property $props

    $bios = Get-CimInstance `
        -ClassName "hpqBIntM" `
        -Namespace "root\wmi" `
        -CimSession $script:HpSession `
        -OperationTimeoutSec $WmiTimeoutSec

    $method = "hpqBIOSInt$OutputSize"

    $result = Invoke-CimMethod `
        -InputObject $bios `
        -MethodName $method `
        -Arguments @{ InData = [Microsoft.Management.Infrastructure.CimInstance]$inData } `
        -OperationTimeoutSec $WmiTimeoutSec

    if ($null -eq $result -or $null -eq $result.OutData) {
        throw ("HP WMI command 0x{0:X2} returned no OutData." -f $CommandType)
    }

    $rc = [int]$result.OutData.rwReturnCode
    if ($rc -ne 0) {
        throw ("HP WMI command 0x{0:X2} failed with return code {1}." -f $CommandType,$rc)
    }
}

function Invoke-HpMaximumGpuState {
    Write-Step "HP firmware state"

    $script:HpSession = New-CimSession `
        -Name ("Victus115W-" + [guid]::NewGuid().ToString("N")) `
        -SkipTestConnection

    try {
        $probe = Get-CimInstance `
            -ClassName "hpqBIntM" `
            -Namespace "root\wmi" `
            -CimSession $script:HpSession `
            -OperationTimeoutSec $WmiTimeoutSec

        if ($null -eq $probe) {
            throw "HP root\wmi:hpqBIntM was not found."
        }

        Write-Host "hpqBIntM: found" -ForegroundColor Green

        # HPCM low nibble = 1 so the firmware's NPCF dynamic path is eligible.
        Send-HpBiosWmi -CommandType 0x1A -Data ([Byte[]]@(0xFF,0x01))
        Write-Host "HPCM / LegacyPerformance: 0x01"

        # cTGP=On, PPAB=On, DState=D1
        Send-HpBiosWmi -CommandType 0x22 -Data ([Byte[]]@(0x01,0x01,0x01,0x00))
        Write-Host "GPU Maximum: cTGP ON + PPAB ON + D1"

        # Hold the tested stock concurrent value; PCF controls the final ceiling.
        Send-HpBiosWmi -CommandType 0x29 -Data ([Byte[]]@(0xFF,0xFF,0xFF,0x23))
        Write-Host "Cpu:PLGpu: 35 W"
    }
    finally {
        if ($script:HpSession) {
            Remove-CimSession -CimSession $script:HpSession -ErrorAction SilentlyContinue
            $script:HpSession = $null
        }
    }
}

if (-not (Test-Admin)) {
    throw "Run PowerShell as Administrator."
}

$dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
if (-not $dotnet) {
    throw @"
dotnet.exe was not found.

Install the current .NET 8+ SDK, then rerun:
https://dotnet.microsoft.com/download
"@
}

if ($GpuMaxW -gt 115) {
    throw "This utility will not set the RTX 5060 PCF GPU maximum above 115 W."
}

$buildDir = Join-Path $env:LOCALAPPDATA "VictusRTX5060Pcf115W"
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

$projPath = Join-Path $buildDir "VictusRTX5060Pcf115W.csproj"
$programPath = Join-Path $buildDir "Program.cs"
$markerPath = Join-Path $buildDir "build-version.txt"

$csproj = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="LLT.NvAPIWrapper.Net" Version="$PackageVersion" />
  </ItemGroup>
</Project>
"@

$program = @'
using System.Diagnostics;
using System.Globalization;
using NvAPIWrapper.GPU;

internal static class Program
{
    static string Watts(uint mw) =>
        mw == uint.MaxValue ? "RELEASE" : $"{mw / 1000.0:F3} W";

    static void PrintPcf(PcfPowerController c, string tag)
    {
        var v = c.GetPowerValues();

        Console.WriteLine(
            $"{tag}: TargetTPP={Watts(v.ACTargetTPPLimitInMilliwatts)}, " +
            $"DefaultGPU={Watts(v.ACDefaultGPULimitInMilliwatts)}, " +
            $"MinGPU={Watts(v.ACMinGPULimitInMilliwatts)}, " +
            $"MaxGPU={Watts(v.ACMaxGPULimitInMilliwatts)}");
    }

    static void PrintSmi()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "nvidia-smi.exe",
                Arguments =
                    "--query-gpu=power.draw,enforced.power.limit,power.default_limit," +
                    "power.max_limit,clocks_event_reasons.sw_power_cap," +
                    "clocks_event_reasons.hw_power_brake_slowdown " +
                    "--format=csv,noheader,nounits",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var p = Process.Start(psi);
            if (p is null)
            {
                Console.WriteLine("SMI: unable to start nvidia-smi");
                return;
            }

            var line = p.StandardOutput.ReadLine();
            p.WaitForExit(3000);

            Console.WriteLine($"SMI: {line}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"SMI unavailable: {ex.Message}");
        }
    }

    public static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine(
                "Usage: helper status | apply <platformW> <gpuMaxW> | stock");
            return 2;
        }

        var mode = args[0].ToLowerInvariant();

        try
        {
            using var controller = new PcfPowerController();

            Console.WriteLine($"PCF ControllerIndex={controller.ControllerIndex}");
            Console.WriteLine($"PCF ControllerMask=0x{controller.ControllerMask:X8}");
            Console.WriteLine(
                $"PCF Layout={controller.Layout}, version=0x{controller.LayoutVersion:X8}");
            Console.WriteLine(
                $"Dynamic Boost enabled={controller.GetDynamicBoostEnabled()}");

            PrintPcf(controller, "BEFORE");
            PrintSmi();

            switch (mode)
            {
                case "status":
                    return 0;

                case "apply":
                {
                    if (args.Length < 3)
                        throw new ArgumentException("apply requires platformW and gpuMaxW");

                    var platformW = int.Parse(args[1], CultureInfo.InvariantCulture);
                    var gpuMaxW = int.Parse(args[2], CultureInfo.InvariantCulture);

                    if (platformW < 125 || platformW > 180)
                        throw new ArgumentOutOfRangeException(
                            nameof(platformW), "Allowed platform TargetTPP range is 125-180 W.");

                    if (gpuMaxW < 100 || gpuMaxW > 115)
                        throw new ArgumentOutOfRangeException(
                            nameof(gpuMaxW), "GPU PCF max is bounded to 100-115 W.");

                    var gpuMaxMw = checked((uint)gpuMaxW * 1000u);
                    var targetMw = checked((uint)platformW * 1000u);

                    controller.SetPowerField(
                        PcfPowerFields.ACMaxGPULimit,
                        gpuMaxMw);

                    controller.SetPowerField(
                        PcfPowerFields.ACTargetTPPLimit,
                        targetMw);

                    Thread.Sleep(800);

                    PrintPcf(controller, "AFTER APPLY");
                    PrintSmi();

                    return 0;
                }

                case "stock":
                {
                    controller.SetPowerField(
                        PcfPowerFields.ACMaxGPULimit,
                        100000u);

                    controller.SetPowerField(
                        PcfPowerFields.ACTargetTPPLimit,
                        125000u);

                    Thread.Sleep(800);

                    PrintPcf(controller, "AFTER STOCK RESTORE");
                    PrintSmi();

                    return 0;
                }

                default:
                    throw new ArgumentException($"Unknown mode: {mode}");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }
}
'@

$buildVersion = "$PackageVersion|v1"

$needBuild = $true
if ((Test-Path -LiteralPath $projPath) -and
    (Test-Path -LiteralPath $programPath) -and
    (Test-Path -LiteralPath $markerPath)) {

    $oldMarker = (Get-Content -LiteralPath $markerPath -Raw).Trim()

    if ($oldMarker -eq $buildVersion) {
        $dll = Join-Path $buildDir "bin\Release\net8.0\VictusRTX5060Pcf115W.dll"
        if (Test-Path -LiteralPath $dll) {
            $needBuild = $false
        }
    }
}

if ($needBuild) {
    Write-Step "Build NVIDIA PCF helper"

    Set-Content -LiteralPath $projPath -Value $csproj -Encoding UTF8
    Set-Content -LiteralPath $programPath -Value $program -Encoding UTF8

    Push-Location $buildDir
    try {
        & $dotnet.Source restore $projPath
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet restore failed with exit code $LASTEXITCODE."
        }

        & $dotnet.Source build $projPath -c Release --no-restore
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet build failed with exit code $LASTEXITCODE."
        }

        Set-Content -LiteralPath $markerPath -Value $buildVersion -Encoding ASCII
    }
    finally {
        Pop-Location
    }
}

if ($Mode -eq "Apply") {
    Invoke-HpMaximumGpuState
}

Write-Step "NVIDIA PCF $Mode"

Push-Location $buildDir
try {
    switch ($Mode) {
        "Apply" {
            & $dotnet.Source run `
                --project $projPath `
                -c Release `
                --no-build `
                -- `
                apply `
                $PlatformTargetW `
                $GpuMaxW
        }

        "Status" {
            & $dotnet.Source run `
                --project $projPath `
                -c Release `
                --no-build `
                -- `
                status
        }

        "Stock" {
            & $dotnet.Source run `
                --project $projPath `
                -c Release `
                --no-build `
                -- `
                stock
        }
    }

    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    throw "PCF helper failed with exit code $exitCode."
}

Write-Host ""
switch ($Mode) {
    "Apply" {
        Write-Host "RTX 5060 PCF unlock applied." -ForegroundColor Green
        Write-Host "Platform TargetTPP : $PlatformTargetW W"
        Write-Host "AC Max GPU Limit   : $GpuMaxW W"
        Write-Host ""
        Write-Host "Verify under a GPU-heavy load with:" -ForegroundColor Yellow
        Write-Host 'nvidia-smi --query-gpu=power.draw,enforced.power.limit,power.max_limit,clocks_event_reasons.sw_power_cap --format=csv'
    }

    "Stock" {
        Write-Host "Stock PCF limits restored." -ForegroundColor Green
        Write-Host "Platform TargetTPP : 125 W"
        Write-Host "AC Max GPU Limit   : 100 W"
    }

    "Status" {
        Write-Host "Status read complete." -ForegroundColor Green
    }
}
