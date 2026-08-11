"""Small-memory PAM4 maximum-likelihood sequence detector."""

from __future__ import annotations

from itertools import product

import numpy as np
from numpy.typing import NDArray

FloatArray = NDArray[np.float64]


def mlse_detect(samples: FloatArray, channel_taps: FloatArray) -> FloatArray:
    """Viterbi MLSE for a real PAM4 channel with up to three-symbol memory."""
    taps = np.asarray(channel_taps, dtype=np.float64)
    if taps.ndim != 1 or taps.size < 1 or taps.size > 4:
        raise ValueError("channel_taps must contain one to four values")
    levels = np.array([-3.0, -1.0, 1.0, 3.0], dtype=np.float64)
    memory = taps.size - 1
    if memory == 0:
        return levels[np.argmin(np.abs(samples[:, None] - taps[0] * levels[None, :]), axis=1)]

    states = list(product(levels, repeat=memory))
    state_index = {state: index for index, state in enumerate(states)}
    metrics = np.full(len(states), np.inf)
    metrics[0] = 0.0
    predecessors = np.zeros((samples.size, len(states)), dtype=np.int32)
    symbols = np.zeros((samples.size, len(states)), dtype=np.float64)

    for time_index, observation in enumerate(samples):
        next_metrics = np.full(len(states), np.inf)
        for previous_index, state in enumerate(states):
            if not np.isfinite(metrics[previous_index]):
                continue
            for symbol in levels:
                history = (symbol,) + state
                expected = float(np.dot(taps, np.asarray(history[: taps.size])))
                next_state = history[:memory]
                next_index = state_index[next_state]
                metric = metrics[previous_index] + (observation - expected) ** 2
                if metric < next_metrics[next_index]:
                    next_metrics[next_index] = metric
                    predecessors[time_index, next_index] = previous_index
                    symbols[time_index, next_index] = symbol
        metrics = next_metrics

    state = int(np.argmin(metrics))
    detected = np.empty(samples.size, dtype=np.float64)
    for time_index in range(samples.size - 1, -1, -1):
        detected[time_index] = symbols[time_index, state]
        state = int(predecessors[time_index, state])
    return detected

