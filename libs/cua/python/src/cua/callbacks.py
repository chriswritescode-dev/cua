"""cua.callbacks — agent lifecycle callback handlers.

Usage::

    from cua.callbacks import LoggingCallback, BudgetManagerCallback

Needs the ``agent`` extra: ``pip install 'cua[agent]'``.
"""

from cua_agent.callbacks import (
    AsyncCallbackHandler,
    BudgetManagerCallback,
    ImageRetentionCallback,
    LoggingCallback,
    OperatorNormalizerCallback,
    PromptInstructionsCallback,
    TrajectorySaverCallback,
)

__all__ = [
    "AsyncCallbackHandler",
    "ImageRetentionCallback",
    "LoggingCallback",
    "TrajectorySaverCallback",
    "BudgetManagerCallback",
    "OperatorNormalizerCallback",
    "PromptInstructionsCallback",
]
