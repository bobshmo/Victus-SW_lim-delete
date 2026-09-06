# HP Victus RTX 5060 — 100 W GPU Cap Unlock

We found the source of the 100 W GPU limit on an HP Victus 15 with an RTX 5060 Laptop GPU.

The GPU/VBIOS already reports a **115 W maximum**, but NVIDIA Platform Control Framework (PCF/NVPCF) was configured with:

- AC Target TPP: **125 W**
- AC Default GPU: **90 W**
- AC Min GPU: **80 W**
- **AC Max GPU: 100 W**
- Dynamic Boost: **Enabled**

So the missing 15 W was **not a VBIOS maximum-TGP limitation**. The effective ceiling was being imposed through NVIDIA PCF.

## Working unlock

The proven working combination was:

```text
HP firmware:
HPCM / Legacy Performance = 0x01
cTGP                      = ON
PPAB                      = ON
DState                    = D1
Cpu:PLGpu                 = 35 W

NVIDIA PCF:
ACTargetTPPLimit          = 150 W
ACMaxGPULimit             = 115 W
```

Measured results:

```text
TargetTPP 125 W + GPU Max 115 W
  Max enforced limit: ~93.9 W

TargetTPP 140 W + GPU Max 115 W
  Max actual GPU draw: 103.51 W
  Max enforced limit: 108.12 W

TargetTPP 150 W + GPU Max 115 W
  Enforced power limit: 115.00 W
  NVIDIA reported max: 115.00 W
  HW Power Brake: Not Active
```

At 140 W platform TargetTPP, actual GPU draw already exceeded the old 100 W wall. At 150 W TargetTPP, NVIDIA exposed the full **115 W enforced ceiling**.

`ACTargetTPPLimit = 150 W` does **not** mean the GPU is being commanded to consume 150 W. It is a platform/shared power target. The GPU-specific PCF maximum remains bounded to **115 W**, which is the maximum reported by this RTX 5060.

## Utility

The included PowerShell utility applies the proven values, reads current PCF status, or restores the original limits:

[`Victus-RTX5060-PCF-115W.ps1`](./Victus-RTX5060-PCF-115W.ps1)

### Apply

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Victus-RTX5060-PCF-115W.ps1
```

### Status

```powershell
.\Victus-RTX5060-PCF-115W.ps1 -Mode Status
```

### Restore stock PCF values

```powershell
.\Victus-RTX5060-PCF-115W.ps1 -Mode Stock
```

Original values on the tested machine:

```text
TargetTPP       = 125 W
ACDefaultGPU    = 90 W
ACMinGPU        = 80 W
ACMaxGPU        = 100 W
```

## What this suggests for other Victus / OMEN laptops

If your laptop reports a higher NVIDIA `power.max_limit` than its actual `enforced.power.limit`, the restriction may be coming from **NVIDIA Platform Controllers and Framework (PCF/NVPCF)** rather than the VBIOS.

Useful PCF fields to inspect are:

```text
ACTargetTPPLimit
ACDefaultGPULimit
ACMinGPULimit
ACMaxGPULimit
```

On this machine the key mismatch was:

```text
NVIDIA / VBIOS maximum = 115 W
PCF ACMaxGPULimit      = 100 W
```

## Warning

These values were tested on one specific HP Victus RTX 5060 configuration. Do not blindly copy them to another laptop or GPU. Verify your own VBIOS/NVIDIA maximum, cooling capability, AC adapter, PCF layout, and original PCF values first.

The utility intentionally refuses to set `ACMaxGPULimit` above **115 W**.
