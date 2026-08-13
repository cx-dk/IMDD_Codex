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

本工程采用普通源码文件和 `include`，不定义 Julia module。需要完整发射机时，
只包含统一入口 `src/IMDD.jl`：

```julia
using Pkg
Pkg.activate("julia")
include("julia/src/IMDD.jl")

# seed 的 bit i 对应寄存器 Si；最低有效位对应 S0。
bits = PatternBits("prbs13q", 1024; seed=0b1101010100000)
codes = GrayMapPam4Codes(bits) # 标准 PAM4 symbol code 0, 1, 2, 3
levels = GrayMapPam4(bits)      # 归一化电平 -1, -1/3, +1/3, +1

# 完整的固定 SSPRQ 周期；seed 对 SSPRQ 无效。
ssprq = SsprqSymbols()           # 65535 个 UInt8 symbol codes
```

只调试序列生成时，可以仅包含：

```julia
include("julia/src/IMDDPatterns.jl")
```

如果希望逐文件观察加载关系，完整发射机等价于：

```julia
include("julia/src/IMDDPatterns.jl")
include("julia/src/IMDDTransmitterConfig.jl")
include("julia/src/IMDDTransmitter.jl")
include("julia/src/IMDDTransmitterSetup.jl")
```

依赖安装只需首次执行一次 `Pkg.instantiate()`；普通调试和运行不需要重复执行。

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
julia --project=julia --startup-file=no julia/test/runtests.jl
```

## 单通道 IMDD 发射机

`src/IMDDTransmitter.jl` 参考 Python 平台的单 lane 发射链路，采用过程式组织，
每个阶段都可以单独调用和测试：

1. `RunTxDsp`：完成 pattern、PAM4 映射、零插值过采样、TxFIR 和可选的
   无记忆多项式非线性预补偿；
2. `CalculateOptimalTxGain`：独立计算量化感知的 DAC 输入增益，在量化误差和
   过载削顶之间自适应折中；
3. `GenerateDacWaveform`：接收增益调整后的采样流，执行采样抖动、满量程裁剪、
   均匀量化、DAC 输出噪声和重建低通；
4. `RunImddTransmitter`：按上述顺序调用 Tx DSP、增益控制和 DAC，仅返回 DAC
   输出向量。

TxFIR 抽头是过采样速率下的 sample-spaced 系数。空抽头向量表示使用
`ones(samples_per_symbol)` 的默认矩形滤波器。DAC 默认为 8 bit、归一化
满量程 ±1、零抖动和零输出噪声。

非线性补偿多项式定义为 `y = c₁x + c₂x² + ... + cₙxⁿ`，不包含常数项；
`[1.0]` 表示单位传输。增益控制支持 `"adaptive"` 和 `"fixed"` 两种模式。
自适应模式以输入折算量化均方误差为代价函数，并同时考虑 DAC 削顶；固定模式
直接采用 `tx_fixed_gain`，便于参数扫描和硬件标定。

`CwLaser`、`AddRin`、`MzmModulate` 和 `EmlModulate` 保持为独立光器件函数，
可在后续光发射链中接收 DAC 输出，但不增加电发端的返回结构。

### 统一参数结构

`RunImddTransmitter` 只接收一个 `ImddTransmitterParameters`。器件和 DSP 参数
分别存放，并由顶层主种子统一控制所有噪声：

| 参数组 | 内容 |
|---|---|
| `parameters.noise_seed` | DAC 抖动/噪声、激光器线宽和 RIN 的统一主随机种子 |
| `parameters.dsp` | pattern、符号率、过采样、TxFIR、非线性预补偿和 DAC 前增益控制 |
| `parameters.device` | DAC/Driver 参数，以及供独立光器件函数使用的激光器、MZM/EML 参数 |

两个子结构及顶层主种子都是可变的，适合在调试和参数扫描时只修改目标字段。完整字段、单位和
模型含义可以在 Julia 中分别查看 `?ImddDeviceParameters`、
`?ImddDspParameters` 和 `?ImddTransmitterParameters`。

`src/IMDDTransmitterSetup.jl` 提供普通函数 `DefineTransmitterParameters()`。
所有仿真配置均在该函数体内显式定义；修改函数内的值后，其返回参数可以直接传给
下一个处理函数：

```julia
using Pkg
Pkg.activate("julia")
include("julia/src/IMDD.jl")

# 第一个普通函数定义并返回参数。
parameters = DefineTransmitterParameters()

# 返回值直接输入第二个函数。
dac_output = RunImddTransmitter(parameters)
```

也可以在两步之间临时修改参数，适合交互式调试：

```julia
parameters = DefineTransmitterParameters()
parameters.dsp.symbol_count = 128
parameters.dsp.tx_gain_mode = "fixed"
parameters.dsp.tx_fixed_gain = 0.8
parameters.device.dac_noise_rms = 0.001

dac_output = RunImddTransmitter(parameters)
```

`CreateNoiseRng` 会从主种子派生 `:dac`、`:laser` 和 `:rin` 三个固定且相互独立的
随机流。相同主种子能够严格复现波形，同时某个器件是否启用、消耗多少随机数都不会
移动其他器件的随机序列。独立调用光器件模型时可以直接传统一参数：

```julia
laser_field = CwLaser(
    length(dac_output),
    parameters.dsp.symbol_rate_hz * parameters.dsp.samples_per_symbol,
    parameters.device.laser_power_dbm,
    parameters.device.laser_linewidth_hz,
    parameters,
)
laser_with_rin = AddRin(
    laser_field,
    parameters.dsp.symbol_rate_hz * parameters.dsp.samples_per_symbol,
    parameters.device.rin_db_hz,
    parameters,
)
```

需要单独检查 Tx DSP 输出和自适应增益时：

```julia
tx_dsp_output = RunTxDsp(parameters.dsp)
optimal_gain = CalculateOptimalTxGain(
    tx_dsp_output,
    parameters.device.dac_resolution_bits;
    full_scale=parameters.device.dac_full_scale,
)
```

MZM 有限消光比由推挽双臂幅度不平衡建模，最小光功率传输为
`10^(-extinction_ratio_db/10)`。将消光比设为 `Inf` 可恢复理想余弦 MZM。

命令行运行并导出 DAC 输出：

```powershell
julia --project=julia julia/bin/run_transmitter.jl `
  --pattern prbs13q `
  --symbols 4096 `
  --pattern-seed 1 `
  --noise-seed 20260811 `
  --dac-bits 8 `
  --dac-jitter-ui 0.002 `
  --dac-noise-rms 0.001 `
  --tx-fir-taps 1.0,1.0,1.0,1.0 `
  --nonlinear-coefficients 1.0,0.0,0.1 `
  --gain-mode adaptive `
  --output output/tx_lane.csv
```

发射机测试单独位于 `julia/test/transmitter_tests.jl`，由总测试入口一并执行。

## Include 调试方式

`src/IMDD.jl` 是普通 include 入口，不创建命名空间。加载后可直接在 REPL 中调用
`PatternBits`、`RunTxDsp`、`CalculateOptimalTxGain` 和
`RunImddTransmitter`，也可以在这些函数内设置断点。

PRBS 抽头、SSPRQ 分段和噪声流标签等实现数据均封装在查询函数或使用它们的函数
内部，不再以顶层 `const` 出现在 `Main` 的变量区。SSPRQ 固定周期只在实际调用
`SsprqSymbols` 时生成，以保持全局变量区整洁。

Julia 的 `struct` 不能在同一个作用域内重复定义，所以一个 REPL 会话中不要反复
include `IMDDTransmitterConfig.jl` 或完整入口。修改普通函数后可以重新启动脚本；
修改 `DefineTransmitterParameters()` 中的配置值后，可以只重新 include
`IMDDTransmitterSetup.jl`，无需重新加载结构体或算法；修改参数结构体本身时才需要
重新启动 Julia 会话。这与是否使用 module 无关，是 Julia 类型定义本身的限制。

推荐从仓库根目录启动：

```powershell
julia --project=julia
```

随后在 REPL 中执行一次：

```julia
include("julia/src/IMDD.jl")
```

修改参数配置函数后，在同一 REPL 中刷新配置函数：

```julia
include("julia/src/IMDDTransmitterSetup.jl")
parameters = DefineTransmitterParameters()
dac_output = RunImddTransmitter(parameters)
```
