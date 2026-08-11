# IMDD PAM4 Simulation Platform

CPU-only、跨 Windows/Linux 的模块化 IMDD PAM4 仿真平台。当前版本提供第一条可运行的端到端链路，并为 Retimed、LPO、LRO、NPO、CEI 和 PCIe-over-Optics 扩展预留稳定接口。

## 当前能力

- IEEE 802.3 标准 Profile 注册与版本/草案状态标记
- 100G/lane 与 200G/lane DR/FR 配置基线
- PRBS13Q/PRBS31Q、Gray PAM4、可配置波特率与不少于 4 SPS 的发射波形
- CW 激光器、MZM、EML
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

运行示例：

```bash
imdd-sim run --config configs/ethernet_400gbase_fr4.toml
```

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
