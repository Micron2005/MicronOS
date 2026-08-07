"""The Micron OS Assistant Interface.

Micron OS is an operating system. An assistant is a PROGRAM someone installs
onto it -- theirs, anyone's. This file is the whole contract between the two:
implement this class, name your module in configs/micron.toml, and Micron OS
hosts YOUR assistant. Alfred is merely the first implementation.

An assistant provider module must expose:

    def create_provider(loop) -> AssistantProvider

and the returned object implements the methods below. All async methods run
on the OS's event loop; the OS bridges its HTTP threads across for you.
"""

from __future__ import annotations


class AssistantProvider:
    """Subclass (or duck-type) this. Only `name` and `chat` are required for
    a minimal assistant; everything else may raise NotImplementedError and
    the OS degrades those surfaces honestly."""

    name: str = "assistant"

    async def start(self) -> None:
        """Bring the assistant to life (models, buses, background tasks)."""

    async def chat(self, message: str, project_id: str | None = None,
                   attachments: list[str] | None = None) -> str:
        raise NotImplementedError

    async def status(self) -> dict:
        """Household extras for the shell's panels. Return {} for none.
        Recognised keys: nodes, workers, pending_actions, projects, notices,
        default_project."""
        return {}

    async def approve_action(self, action_id: int) -> dict:
        raise NotImplementedError

    async def decline_action(self, action_id: int) -> dict:
        raise NotImplementedError

    async def speech_capabilities(self) -> set[str]:
        return set()

    async def transcribe(self, audio: bytes, fmt: str) -> str:
        raise NotImplementedError

    async def synthesize(self, text: str) -> bytes:
        raise NotImplementedError

    async def stop(self) -> None:
        """Graceful shutdown."""
