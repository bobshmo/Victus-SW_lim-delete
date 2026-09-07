#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$AppName = "NVmobile Demuzzler"
$PackageVersion = "1.1.24-pre.38"
$WmiTimeoutSec = 8
$GpuMaxW = 115
$StockPLGpuW = 35
$StockTPPW = 125
$StockGpuMaxW = 100
$DefaultPLGpuW = 71
$DefaultTPPW = 180

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Show-Error([string]$Text) {
    [System.Windows.Forms.MessageBox]::Show($Text,$AppName,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}
function Log-Line([System.Windows.Forms.TextBox]$Box,[string]$Text) {
    $Box.AppendText("[$(Get-Date -Format HH:mm:ss)] $Text`r`n")
    $Box.SelectionStart = $Box.Text.Length
    $Box.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}
function Send-HpBiosWmi {
    param([UInt32]$CommandType,[Byte[]]$Data=$null,[int]$OutputSize=0,[UInt32]$Command=0x20008)
    [UInt32]$dataSize = if ($null -eq $Data) { 0 } else { $Data.Length }
    $props = @{
        Command=$Command; CommandType=$CommandType; Size=$dataSize; Sign=[Byte[]]@(0x53,0x45,0x43,0x55)
    }
    if ($null -ne $Data) { $props["hpqBData"] = $Data }
    $inData = New-CimInstance -ClassName "hpqBDataIn" -Namespace "root\wmi" -ClientOnly -Property $props
    $bios = Get-CimInstance -ClassName "hpqBIntM" -Namespace "root\wmi" -CimSession $script:HpSession -OperationTimeoutSec $WmiTimeoutSec
    $result = Invoke-CimMethod -InputObject $bios -MethodName "hpqBIOSInt$OutputSize" -Arguments @{InData=[Microsoft.Management.Infrastructure.CimInstance]$inData} -OperationTimeoutSec $WmiTimeoutSec
    if ($null -eq $result -or $null -eq $result.OutData) { throw "HP WMI returned no OutData." }
    $rc=[int]$result.OutData.rwReturnCode
    if ($rc -ne 0) { throw "HP WMI command 0x$('{0:X2}' -f $CommandType) failed with return code $rc." }
}
function Apply-HpState {
    param([int]$PLGpuW)
    if ($PLGpuW -lt 0 -or $PLGpuW -gt 255) { throw "PLGPU must be 0-255 W." }
    $script:HpSession = New-CimSession -Name ("NVmobileDemuzzler-" + [guid]::NewGuid().ToString("N")) -SkipTestConnection
    try {
        $probe = Get-CimInstance -ClassName "hpqBIntM" -Namespace "root\wmi" -CimSession $script:HpSession -OperationTimeoutSec $WmiTimeoutSec
        if ($null -eq $probe) { throw "HP root\wmi:hpqBIntM not found." }
        Send-HpBiosWmi -CommandType 0x1A -Data ([Byte[]]@(0xFF,0x01))
        Send-HpBiosWmi -CommandType 0x22 -Data ([Byte[]]@(0x01,0x01,0x01,0x00))
        Send-HpBiosWmi -CommandType 0x29 -Data ([Byte[]]@(0xFF,0xFF,0xFF,[Byte]$PLGpuW))
    } finally {
        if ($script:HpSession) { Remove-CimSession -CimSession $script:HpSession -ErrorAction SilentlyContinue; $script:HpSession=$null }
    }
}
function Ensure-Helper {
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $dotnet) { throw "dotnet.exe not found. Install .NET 8+ SDK." }
    $buildDir = Join-Path $env:LOCALAPPDATA "NVmobileDemuzzler"
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    $projPath = Join-Path $buildDir "NVmobileDemuzzler.Helper.csproj"
    $programPath = Join-Path $buildDir "Program.cs"
    $markerPath = Join-Path $buildDir "build-version.txt"
    $dllPath = Join-Path $buildDir "bin\Release\net8.0\NVmobileDemuzzler.Helper.dll"
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
using NvAPIWrapper.GPU;
internal static class Program
{
    static string Watts(uint mw)=>mw==uint.MaxValue?"RELEASE":$"{mw/1000.0:F3} W";
    static void PrintPcf(PcfPowerController c,string tag)
    {
        var v=c.GetPowerValues();
        Console.WriteLine($"{tag}|TargetTPP={Watts(v.ACTargetTPPLimitInMilliwatts)}|DefaultGPU={Watts(v.ACDefaultGPULimitInMilliwatts)}|MinGPU={Watts(v.ACMinGPULimitInMilliwatts)}|MaxGPU={Watts(v.ACMaxGPULimitInMilliwatts)}|DynamicBoost={c.GetDynamicBoostEnabled()}");
    }
    static void PrintSmi()
    {
        try {
            var psi=new ProcessStartInfo {
                FileName="nvidia-smi.exe",
                Arguments="--query-gpu=power.draw,enforced.power.limit,power.default_limit,power.max_limit,clocks_event_reasons.sw_power_cap,clocks_event_reasons.hw_power_brake_slowdown --format=csv,noheader,nounits",
                RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false,CreateNoWindow=true
            };
            using var p=Process.Start(psi);
            if(p==null){Console.WriteLine("SMI|unavailable");return;}
            var line=p.StandardOutput.ReadLine(); p.WaitForExit(3000); Console.WriteLine("SMI|"+line);
        } catch(Exception ex){Console.WriteLine("SMI|ERROR|"+ex.Message);}
    }
    public static int Main(string[] args)
    {
        if(args.Length<1) return 2;
        try {
            using var c=new PcfPowerController();
            Console.WriteLine($"META|ControllerIndex={c.ControllerIndex}|Mask=0x{c.ControllerMask:X8}|Layout={c.Layout}|Version=0x{c.LayoutVersion:X8}");
            PrintPcf(c,"BEFORE"); PrintSmi();
            var mode=args[0].ToLowerInvariant();
            if(mode=="status") return 0;
            if(mode=="apply"){
                int tpp=int.Parse(args[1]); int gpuMax=int.Parse(args[2]);
                if(tpp<100||tpp>180) throw new ArgumentOutOfRangeException(nameof(tpp),"TPP must be 100-180 W.");
                if(gpuMax<100||gpuMax>115) throw new ArgumentOutOfRangeException(nameof(gpuMax),"GPU max must be 100-115 W.");
                c.SetPowerField(PcfPowerFields.ACMaxGPULimit,checked((uint)gpuMax*1000u));
                c.SetPowerField(PcfPowerFields.ACTargetTPPLimit,checked((uint)tpp*1000u));
                Thread.Sleep(600); PrintPcf(c,"AFTER"); PrintSmi(); return 0;
            }
            if(mode=="stock"){
                c.SetPowerField(PcfPowerFields.ACMaxGPULimit,100000u);
                c.SetPowerField(PcfPowerFields.ACTargetTPPLimit,125000u);
                Thread.Sleep(600); PrintPcf(c,"AFTER"); PrintSmi(); return 0;
            }
            throw new ArgumentException("Unknown mode");
        } catch(Exception ex){Console.Error.WriteLine(ex); return 1;}
    }
}
'@
    $buildVersion="$PackageVersion|gui-v1"
    $needBuild=$true
    if((Test-Path $markerPath)-and(Test-Path $dllPath)){
        if((Get-Content $markerPath -Raw).Trim() -eq $buildVersion){$needBuild=$false}
    }
    if($needBuild){
        Set-Content $projPath $csproj -Encoding UTF8
        Set-Content $programPath $program -Encoding UTF8
        Push-Location $buildDir
        try {
            & $dotnet.Source restore $projPath | Out-Null
            if($LASTEXITCODE-ne 0){throw "dotnet restore failed."}
            & $dotnet.Source build $projPath -c Release --no-restore | Out-Null
            if($LASTEXITCODE-ne 0){throw "dotnet build failed."}
            Set-Content $markerPath $buildVersion -Encoding ASCII
        } finally { Pop-Location }
    }
    [pscustomobject]@{DotNet=$dotnet.Source;Project=$projPath}
}
function Invoke-PcfHelper {
    param([ValidateSet("status","apply","stock")][string]$Mode,[int]$TPPW=125)
    $h=Ensure-Helper
    $args=@("run","--project",$h.Project,"-c","Release","--no-build","--",$Mode)
    if($Mode-eq"apply"){$args+=@([string]$TPPW,[string]$GpuMaxW)}
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$h.DotNet
    $psi.Arguments=($args|ForEach-Object{if($_-match'\s'){ '"'+$_+'"' }else{$_}})-join' '
    $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
    $o=$p.StandardOutput.ReadToEnd();$e=$p.StandardError.ReadToEnd();$p.WaitForExit()
    if($p.ExitCode-ne 0){throw(($e+"`r`n"+$o).Trim())}
    $o.Trim()
}
if(-not(Test-Admin)){Show-Error "Run NVmobile Demuzzler as Administrator.";exit 1}

$form=New-Object System.Windows.Forms.Form
$form.Text=$AppName;$form.Size=New-Object Drawing.Size(720,560);$form.StartPosition="CenterScreen";$form.FormBorderStyle="FixedDialog";$form.MaximizeBox=$false
$form.BackColor=[Drawing.Color]::FromArgb(24,24,27);$form.ForeColor=[Drawing.Color]::White

$title=New-Object Windows.Forms.Label;$title.Text=$AppName;$title.Font=New-Object Drawing.Font("Segoe UI",20,[Drawing.FontStyle]::Bold);$title.AutoSize=$true;$title.Location=New-Object Drawing.Point(24,18);$form.Controls.Add($title)
$sub=New-Object Windows.Forms.Label;$sub.Text="NVIDIA mobile PCF + HP PLGPU control";$sub.AutoSize=$true;$sub.ForeColor=[Drawing.Color]::Gainsboro;$sub.Location=New-Object Drawing.Point(28,58);$form.Controls.Add($sub)

$lblPL=New-Object Windows.Forms.Label;$lblPL.Text="PLGPU (W)";$lblPL.AutoSize=$true;$lblPL.Location=New-Object Drawing.Point(30,105);$form.Controls.Add($lblPL)
$numPL=New-Object Windows.Forms.NumericUpDown;$numPL.Minimum=0;$numPL.Maximum=255;$numPL.Value=$DefaultPLGpuW;$numPL.Location=New-Object Drawing.Point(30,130);$numPL.Size=New-Object Drawing.Size(150,28);$form.Controls.Add($numPL)

$lblTPP=New-Object Windows.Forms.Label;$lblTPP.Text="Target TPP (W)";$lblTPP.AutoSize=$true;$lblTPP.Location=New-Object Drawing.Point(220,105);$form.Controls.Add($lblTPP)
$numTPP=New-Object Windows.Forms.NumericUpDown;$numTPP.Minimum=100;$numTPP.Maximum=180;$numTPP.Value=$DefaultTPPW;$numTPP.Location=New-Object Drawing.Point(220,130);$numTPP.Size=New-Object Drawing.Size(150,28);$form.Controls.Add($numTPP)

$lblMax=New-Object Windows.Forms.Label;$lblMax.Text="GPU Max: 115 W";$lblMax.AutoSize=$true;$lblMax.Location=New-Object Drawing.Point(410,133);$form.Controls.Add($lblMax)

$btnApply=New-Object Windows.Forms.Button;$btnApply.Text="Apply";$btnApply.Location=New-Object Drawing.Point(30,185);$btnApply.Size=New-Object Drawing.Size(140,38);$form.Controls.Add($btnApply)
$btnStatus=New-Object Windows.Forms.Button;$btnStatus.Text="Status";$btnStatus.Location=New-Object Drawing.Point(185,185);$btnStatus.Size=New-Object Drawing.Size(140,38);$form.Controls.Add($btnStatus)
$btnStock=New-Object Windows.Forms.Button;$btnStock.Text="Restore Stock";$btnStock.Location=New-Object Drawing.Point(340,185);$btnStock.Size=New-Object Drawing.Size(140,38);$form.Controls.Add($btnStock)
$btnPreset=New-Object Windows.Forms.Button;$btnPreset.Text="71 / 180 Preset";$btnPreset.Location=New-Object Drawing.Point(495,185);$btnPreset.Size=New-Object Drawing.Size(155,38);$form.Controls.Add($btnPreset)

$log=New-Object Windows.Forms.TextBox;$log.Multiline=$true;$log.ScrollBars="Vertical";$log.ReadOnly=$true;$log.BackColor=[Drawing.Color]::FromArgb(15,15,17);$log.ForeColor=[Drawing.Color]::Gainsboro;$log.Font=New-Object Drawing.Font("Consolas",9);$log.Location=New-Object Drawing.Point(30,250);$log.Size=New-Object Drawing.Size(620,240);$form.Controls.Add($log)
$footer=New-Object Windows.Forms.Label;$footer.Text="TPP: 100–180 W | PLGPU: 0–255 | GPU max fixed at 115 W";$footer.AutoSize=$true;$footer.ForeColor=[Drawing.Color]::Silver;$footer.Location=New-Object Drawing.Point(30,500);$form.Controls.Add($footer)

$btnPreset.Add_Click({$numPL.Value=71;$numTPP.Value=180;Log-Line $log "Loaded 71 W PLGPU / 180 W TPP preset."})
$btnApply.Add_Click({
    try{
        $pl=[int]$numPL.Value;$tpp=[int]$numTPP.Value
        Log-Line $log "Applying PLGPU=$pl W..."
        Apply-HpState $pl
        Log-Line $log "Applying TPP=$tpp W / GPU Max=$GpuMaxW W..."
        $out=Invoke-PcfHelper apply $tpp
        foreach($line in($out-split"`r?`n")){if($line.Trim()){Log-Line $log $line.Trim()}}
        Log-Line $log "Apply complete."
    }catch{Log-Line $log ("ERROR: "+$_.Exception.Message);Show-Error $_.Exception.Message}
})
$btnStatus.Add_Click({
    try{
        Log-Line $log "Reading live status..."
        $out=Invoke-PcfHelper status
        foreach($line in($out-split"`r?`n")){if($line.Trim()){Log-Line $log $line.Trim()}}
    }catch{Log-Line $log ("ERROR: "+$_.Exception.Message);Show-Error $_.Exception.Message}
})
$btnStock.Add_Click({
    try{
        $r=[Windows.Forms.MessageBox]::Show("Restore stock PLGPU 35 W / TPP 125 W / GPU Max 100 W?",$AppName,[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
        if($r-ne[Windows.Forms.DialogResult]::Yes){return}
        Apply-HpState $StockPLGpuW
        $out=Invoke-PcfHelper stock
        foreach($line in($out-split"`r?`n")){if($line.Trim()){Log-Line $log $line.Trim()}}
        $numPL.Value=$StockPLGpuW;$numTPP.Value=$StockTPPW
        Log-Line $log "Stock values restored."
    }catch{Log-Line $log ("ERROR: "+$_.Exception.Message);Show-Error $_.Exception.Message}
})
$form.Add_Shown({Log-Line $log "Ready. Defaults: PLGPU 71 W / TPP 180 W / GPU Max 115 W."})
[void]$form.ShowDialog()
