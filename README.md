# IMDD PAM4 Simulation Platform

CPU-only、跨 Windows/Linux 的模块化 IMDD PAM4 仿真平台。当前版本提供第一条可运行的端到端链路，并为 Retimed、LPO、LRO、NPO、CEI 和 PCIe-over-Optics 扩展预留稳定接口。

## 当前能力

- IEEE 802.3 标准 Profile 注册与版本/草案状态标记
- 100G/lane 与 200G/lane DR/FR 配置基线
- PRBS13Q/PRBS31Q、Gray PAM4、可配置波特率与不少于 4 SPS 的发射波形
- Python 与 Julia 使用相同的 IEEE PRBS9/13/31、Clause 120 SSPRQ 和 PAM4 Gray 编解码定义
- CW 激光器、MZM、EML
- TX/RX 实测 S21：Touchstone `.s2p` 或 CSV，可替代理想带宽或与其级联
- G.652.D/G.657.A1/A2 线性色散与损耗
- 可选标量 SSFM SPM，以及高效批量 WDM SPM/XPM 近似
- PIN/TIA、热噪声、散粒噪声、ADC 量化
- 数字插值等效 Mueller-Muller 定时恢复
- FFE、可旁路 DFE、MLSE 和 FFE+Volterra
- pre-FEC BER/SER、PAM4 三眼、EVM、标准限值对照
- CLI、JSON 结果和多进程 Monte Carlo

尚未实现的标准指标会报告为 `not_evaluated`，不会被误判为通过。

## 安装

```powershell
py -3.11 -m pip install -e .
```

Linux：

```bash
python3 -m pip install -e .
```

## 使用

列出 Profile：

```bash
imdd-sim profiles
```

列出 Retimed/LPO/NPO/LRO 对应的电接口标准：

```bash
imdd-sim interfaces
```

列出码型及其 IEEE 标准出处：

```bash
imdd-sim patterns
```

运行示例：

```bash
imdd-sim run --config configs/ethernet_400gbase_fr4.toml
```

运行带实测响应的示例：

```bash
imdd-sim run --config configs/ethernet_400gbase_fr4_measured_s21.toml
```

所有配置项、单位和可选值见 [`configs/config_reference.toml`](configs/config_reference.toml)。

## 实测 S21 文件

Touchstone 输入当前支持两端口 `.s2p`，读取 S21，支持 `RI`、`MA` 和 `DB` 格式。CSV 至少包含频率和幅度列，推荐格式：

```csv
frequency_ghz,magnitude_db,phase_deg
0,-1.0,0
10,-1.4,-45
```

支持的 CSV 列名包括 `frequency_hz/frequency_ghz`、`magnitude_db/s21_db`、`phase_deg/phase_rad`。相位列可省略，此时按零相位处理。相对文件路径以 TOML 配置文件所在目录为基准。

配置可分别放在 `[transmitter.measured_s21]` 和 `[receiver.measured_s21]` 下。`replace_ideal_bandwidth=true` 表示实测响应替代理想低通；设为 `false` 表示两者级联。`normalize_dc=false` 会保留实测插入损耗，`remove_delay=false` 会保留实测群时延。

仓库中的 `measurements/example_tx_driver_s21.csv` 仅用于功能回归和配置演示，不是标准限值或实际器件测量结果。正式仿真应替换为去嵌后、参考阻抗和端口定义明确的 VNA 数据。当前模型使用 S21 作为单向 LTI 响应，不联合求解 S11/S22 引起的源端和负载端失配。

## IEEE 发送与接收序列

Python 的 `models/signal.py` 与 `julia/src/IMDDPatterns.jl` 使用相同定义：

- PRBS9：`1 + x^5 + x^9`
- PRBS13/PRBS13Q：`1 + x + x^2 + x^12 + x^13`
- PRBS31/PRBS31Q：`1 + x^28 + x^31`，输出采用 IEEE Figure 49-9 的反相反馈
- SSPRQ：IEEE 802.3-2022 120.5.11.2.3 和 Table 120-2，固定周期 65535 symbols
- PAM4 Gray：`00, 01, 11, 10 -> symbol code 0, 1, 2, 3 -> level -1, -1/3, +1/3, +1`

`simulation.pattern_seed` 的整数 bit `i` 对应寄存器 `Si`，LSB 对应 `S0`。PRBS seed 必须非零且能放入相应阶数的寄存器，不再静默截断。`pattern_lane_seed_stride=0` 让所有 WDM lane 使用同一个标准序列；需要去相关时设置正数步长。SSPRQ 是固定标准序列，不受 seed 影响。

并行 Monte Carlo：

```bash
imdd-sim monte-carlo --config configs/ethernet_400gbase_fr4.toml --trials 8 --workers 4
```

不安装包时可设置 `PYTHONPATH=src` 后运行 `python -m imdd_sim`。

## 模型口径

- `normative`：参数来自正式标准，可用于标准对照。
- `draft`：参数来自指定草案，只能声明为对该草案的检查。
- `provisional`：标准仍在制定，作为研究模型使用。
- `engineering`：PCIe 光桥等尚无对应标准 PMD 的工程模型。

项目中的标准限值 Profile 为只读基线。研究时可以覆盖参数，但结果会记录 `standard_overrides`，不再声明严格合规。
