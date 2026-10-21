"""Mutable server state: scenario queues, gates, the request log and per-channel config."""

import asyncio
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Any, Optional


@dataclass
class Scenario:
    id: str
    channel: str
    steps: list


class RequestRecord:
    """One request as the app sent it, plus what the mock did with it."""

    def __init__(self, seq: int, channel: str, method: str, path: str, query: dict, headers: dict):
        self.seq = seq
        self.channel = channel
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body: Any = None
        self.scripted = False
        self.scenario_id: Optional[str] = None
        # received → streaming | gate | held → done | disconnected | rejected
        self.state = "received"
        self.status: Optional[int] = None
        self.waiting_gate: Optional[str] = None
        self.client_disconnected = False
        self.mock_error: Optional[str] = None  # set when the mock itself rejected the request
        self.started_at = time.time()
        self.finished_at: Optional[float] = None

    def to_json(self) -> dict:
        return {
            "seq": self.seq, "channel": self.channel, "method": self.method, "path": self.path,
            "query": self.query, "headers": self.headers, "body": self.body, "scripted": self.scripted,
            "scenario_id": self.scenario_id, "state": self.state, "status": self.status,
            "waiting_gate": self.waiting_gate, "client_disconnected": self.client_disconnected,
            "mock_error": self.mock_error, "started_at": self.started_at, "finished_at": self.finished_at,
        }


class State:
    def __init__(self):
        self._seq = 0
        self._scenario_seq = 0
        self.gates: dict = {}
        self.reset()

    def reset(self) -> None:
        # Wake whatever is still waiting on a gate so handlers of a finished test can wind down.
        for event in self.gates.values():
            event.set()
        self.gates = {}
        self.scenarios: dict = defaultdict(deque)
        self.requests: list = []
        self.config: dict = defaultdict(dict)

    # -- requests -----------------------------------------------------------------------------------------

    def new_request(self, channel: str, method: str, path: str, query: dict, headers: dict) -> RequestRecord:
        self._seq += 1
        record = RequestRecord(self._seq, channel, method, path, query, headers)
        self.requests.append(record)
        return record

    # -- scenarios ----------------------------------------------------------------------------------------

    def enqueue(self, channel: str, steps: list) -> Scenario:
        self._scenario_seq += 1
        scenario = Scenario(f"s{self._scenario_seq}", channel, steps)
        self.scenarios[channel].append(scenario)
        return scenario

    def next_scenario(self, channel: str) -> Optional[Scenario]:
        queue = self.scenarios[channel]
        return queue.popleft() if queue else None

    def pending(self) -> list:
        return [{"id": s.id, "channel": s.channel} for q in self.scenarios.values() for s in q]

    # -- gates --------------------------------------------------------------------------------------------

    def gate(self, name: str) -> asyncio.Event:
        return self.gates.setdefault(name, asyncio.Event())

    def release(self, name: str) -> None:
        self.gate(name).set()
