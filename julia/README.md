# Julia data-pattern generator

该目录是与 Python 工程隔离的 Julia 子工程，用于生成 IMDD/PAM4 仿真的数据
pattern。标准型 pattern 按 IEEE Std 802.3-2022 实现。

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

using IMDDPatterns

# seed 的 bit i 对应寄存器 Si；最低有效位对应 S0。
bits = pattern_bits("prbs13q", 1024; seed=0b1101010100000)
codes = gray_map_pam4_codes(bits) # 标准 PAM4 symbol code 0, 1, 2, 3
levels = gray_map_pam4(bits)      # 归一化电平 -1, -1/3, +1/3, +1

# 完整的固定 SSPRQ 周期；seed 对 SSPRQ 无效。
ssprq = ssprq_symbols()           # 65535 个 UInt8 symbol codes
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
