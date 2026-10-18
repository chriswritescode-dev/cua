"""
agent - Decorator-based Computer Use Agent with liteLLM integration
"""

# Import loops to register them
from . import loops
from .agent import ComputerAgent
from .decorators import register_agent
from .types import AgentResponse, Messages

__all__ = ["register_agent", "ComputerAgent", "Messages", "AgentResponse"]

__version__ = "0.4.0"
