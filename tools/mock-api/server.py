#!/usr/bin/env python3
"""Mock provider API server for iCanHazAI's smoke tests. See README.md."""

import argparse
import asyncio
import signal

from aiohttp import web

from control import control_routes, provider_routes, unknown_handler
from state import State


def make_app(state: State) -> web.Application:
    # Chat requests can carry base64 images.
    app = web.Application(client_max_size=256 * 1024 * 1024)
    app.add_routes(control_routes(state))
    app.add_routes(provider_routes(state))
    # Last: anything else is a wrong URL from the app, recorded so tests can tell.
    app.router.add_route("*", "/{tail:.*}", unknown_handler(state))
    return app


async def serve(host: str, port: int) -> None:
    state = State()
    # handler_cancellation: a client disconnect cancels the handler, which is how stops are observed.
    runner = web.AppRunner(make_app(state), handler_cancellation=True, shutdown_timeout=1.0, access_log=None)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    bound = runner.addresses[0][1]
    print(f"LISTENING http://{host}:{bound}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    state.reset()  # release gates so handlers can finish
    await runner.cleanup()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 picks a free port")
    args = parser.parse_args()
    asyncio.run(serve(args.host, args.port))


if __name__ == "__main__":
    main()
