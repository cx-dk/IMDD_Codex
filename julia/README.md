# Julia IMDD pattern 与单通道发射机

该目录是与 Python 工程隔离的 Julia 子工程，用于生成 IMDD/PAM4 仿真的数据
pattern 和单通道发射光场。标准型 pattern 按 IEEE Std 802.3-2022 实现。

首次使用时安装子工程依赖：

```powershell
julia --project=julia -e "using Pkg; Pkg.instantiate()"
```

## 支持的 pattern

IEEE 802.3 pattern：

- `prbs9`：多项式 `1 + x^5 + x^9`（表 68-6）
- `prbs13` / `prbs13q`：Figure 94-6 和 120.5.11.2.1
- `prbs31` / `prbs31q`：Figure 49-9 和 120.5.11.2.2
- `ssprq`：120.5.11.2.3 和表 120-2，固定周期为 65535 PAM4 symbols

另外提供使用常见标准多项式的 `prbs7`、`prbs15`，以及用于工程仿真的
`random`、`zeros`、`ones`、`alternating`、`pam4_cycle` 和 `custom`。
后面这些工程 pattern 不应被表述为 IEEE 合规测试 pattern。

## Julia API

```julia
using Pkg
Pkg.activate("julia")
Pkg.instantiate()

using IMDDPatterns

# seed 的 bit i 对应寄存器 Si；最低有效位对应 S0。
bits = PatternBits("prbs13q", 1024; seed=0b1101010100000)
codes = GrayMapPam4Codes(bits) # 标准 PAM4 symbol code 0, 1, 2, 3
levels = GrayMapPam4(bits)      # 归一化电平 -1, -1/3, +1/3, +1

# 完整的固定 SSPRQ 周期；seed 对 SSPRQ 无效。
ssprq = SsprqSymbols()           # 65535 个 UInt8 symbol codes
```

PRBS seed 必须非零，并且必须能够放入对应阶数的寄存器。函数不会静默截断
或替换非法 seed。

## 命令行

预览序列：

```powershell
julia --project=julia julia/bin/generate_pattern.jl --pattern ssprq --symbols 32
```

导出 CSV：

```powershell
julia --project=julia julia/bin/generate_pattern.jl `
  --pattern prbs31q `
  --symbols 4096 `
  --seed 0x7fffffff `
  --output output/prbs31q.csv
```

CSV 同时包含原始 bit pair、PAM4 symbol code 和归一化电平。

## 测试

测试包含 IEEE 正文中的 PRBS13Q/PRBS31Q 示例，以及 IEEE 官方
`Clause_120_SSPRQ_sequence.csv` 完整序列的摘要校验。

```powershell
julia --startup-file=no --compiled-modules=no julia/test/runtests.jl
```

## 单通道 IMDD 发射机

`src/IMDDTransmitter.jl` 参考 Python 平台的单 lane 发射链路，采用过程式组织，
每个阶段都可以单独调用和测试：

1. `PatternBits`：生成二进制测试序列；
2. `GrayMapPam4Codes` / `GrayMapPam4`：映射 PAM4 symbol code 和归一化电平；
3. `OversampleSymbols`：进行矩形脉冲过采样；
4. `LowpassFft`：施加 FFT 域 Butterworth-like 电带宽限制；
5. `CwLaser` / `AddRin`：生成 CW 光场并加入线宽与 RIN；
6. `MzmModulate` 或 `EmlModulate`：生成单通道 IMDD 发射光场。

总入口 `RunImddTransmitter` 按上述顺序执行，并返回每一级中间波形，方便逐级
打印、绘图和断点调试：

```julia
include("julia/src/IMDDPatterns.jl")
using .IMDDPatterns

result = RunImddTransmitter(
    "prbs13q",
    4096;
    pattern_seed=1,
    noise_seed=20260811,
    symbol_rate_hz=53.125e9,
    samples_per_symbol=4,
    electrical_bandwidth_hz=30.0e9,
    laser_power_dbm=3.0,
    rin_db_hz=-145.0,
    modulator="mzm",
    drive_vpp=1.0,
    vpi_v=2.0,
    bias_phase_rad=pi / 4,
)

result.bits                  # 原始 bits
result.symbols               # 归一化 PAM4 symbols
result.electrical_drive_raw  # 过采样后的原始电驱动
result.electrical_drive      # 带宽限制后的电驱动
result.laser_field           # 含激光器噪声的复光场
result.optical_field         # 调制后的发射光场
result.optical_power_w       # 发射光功率
```

命令行运行并导出所有采样点的中间波形：

```powershell
julia --project=julia julia/bin/run_transmitter.jl `
  --pattern prbs13q `
  --symbols 4096 `
  --pattern-seed 1 `
  --modulator mzm `
  --output output/tx_lane.csv
```

发射机测试单独位于 `julia/test/transmitter_tests.jl`，由总测试入口一并执行。
