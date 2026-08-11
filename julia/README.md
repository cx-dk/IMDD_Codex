# Julia data-pattern generator

该模块为 IMDD/PAM4 仿真生成可复现的数据 pattern。它不依赖第三方 Julia 包，支持：

- `prbs7`、`prbs9`、`prbs13`/`prbs13q`、`prbs15`、`prbs31`/`prbs31q`
- `ssprq` 和带 seed 的 `random`
- `zeros`、`ones`、`alternating`、`pam4_cycle`
- 任意重复的 `custom` bit pattern

直接调用：

```julia
using Pkg
Pkg.activate("julia")

using IMDDPatterns

bits = pattern_bits("prbs13q", 1024; seed=20260811)
symbols = gray_map_pam4(bits)  # 归一化电平：-1, -1/3, +1/3, +1
```

命令行预览或导出 CSV：

```powershell
julia --project=julia julia/bin/generate_pattern.jl --pattern ssprq --symbols 32
julia --project=julia julia/bin/generate_pattern.jl --pattern prbs31q --symbols 4096 --seed 7 --output output/prbs31q.csv
julia --project=julia julia/bin/generate_pattern.jl --custom 001101 --symbols 32
```

Julia 代码、配置和测试全部位于独立的 `julia/` 子工程中，不接入 Python
的 `src/`、`tests/` 或 Python 包环境。运行测试：

```powershell
julia --project=julia -e "using Pkg; Pkg.test()"
```
