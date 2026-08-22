#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# anoled - persistent helper between Anole.app and the iPhone.
#
# WHY A PERSISTENT PROCESS
# The simulated location lives in the developer service channel: it disappears
# as soon as that channel closes. Re-running a command line tool on every
# movement would rebuild the tunnel and lose the location every time.
# So this daemon keeps open, for the whole session: the userspace RSD tunnel,
# the DTX channel, and the simulation service.
#
# PROTOCOL
# One JSON line per message. stdout is strictly NDJSON; all logs go to stderr
# so they do not pollute the data channel.
#
# This file is the only one in the project to import pymobiledevice3
# (GPL-3.0-or-later). It runs in a separate subprocess, which keeps AnoleCore
# and AnoleMac free of that constraint.

import argparse
import asyncio
import json
import logging
import sys
import time

logging.basicConfig(stream=sys.stderr, level=logging.WARNING)

from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

_out_lock = None


def emit(**payload) -> None:
    """Writes an NDJSON message to stdout."""
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


async def read_commands():
    """Reads stdin line by line without blocking the asyncio loop."""
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    while True:
        line = await reader.readline()
        if not line:
            return
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError as exc:
            emit(ev="error", code="bad_json", msg=str(exc))


class Session:
    """State of an open link with the device."""

    def __init__(self, udid=None):
        self.udid = udid
        self.location = None
        # Coalescing: only the last requested location counts. If the interface
        # pushes faster than the device acknowledges, we skip the intermediate
        # locations instead of building up lag.
        self.pending = None
        self.pending_seq = None
        self.wake = asyncio.Event()
        self.stopping = asyncio.Event()
        self.last_sent = None

    def queue(self, latitude, longitude, seq):
        self.pending = (latitude, longitude)
        self.pending_seq = seq
        self.wake.set()

    async def writer_loop(self):
        """Applies the last pending location, continuously."""
        while not self.stopping.is_set():
            await self.wake.wait()
            self.wake.clear()

            coordinate, seq = self.pending, self.pending_seq
            self.pending = None
            if coordinate is None:
                continue

            started = time.perf_counter()
            try:
                await self.location.set(coordinate[0], coordinate[1])
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                emit(ev="error", seq=seq, code="set_failed", msg=f"{type(exc).__name__}: {exc}")
                emit(ev="health", state="lost", msg=str(exc))
                self.stopping.set()
                return
            self.last_sent = coordinate
            emit(ev="ok", seq=seq, rtt_ms=round((time.perf_counter() - started) * 1000, 2))

    async def measure(self, samples):
        """Measures the round-trip time to calibrate the sending rate."""
        base = self.last_sent or (37.7793, -122.4193)
        timings = []
        for index in range(max(1, samples)):
            # Move about one meter on each shot: posting the exact same
            # coordinate again could be short-circuited internally.
            latitude = base[0] + (index % 10) * 0.00001
            started = time.perf_counter()
            await self.location.set(latitude, base[1])
            timings.append((time.perf_counter() - started) * 1000)
        timings.sort()
        pick = lambda q: timings[min(len(timings) - 1, int(len(timings) * q))]
        return {
            "p50": round(pick(0.50), 2),
            "p95": round(pick(0.95), 2),
            "max": round(timings[-1], 2),
        }


async def serve(udid):
    session = Session(udid)

    emit(ev="progress", step="startingTunnel")
    # Userspace tunnel: no privilege elevation is required.
    async with UserspaceRsdTunnel(serial=udid, autopair=True) as rsd:
        emit(ev="progress", step="connectingDeveloperServices")

        # DvtProvider carries the DTX service names; the base class does not.
        # LocationSimulation must be opened as a context manager: it is what
        # allocates the channel, and the channel holds the simulated location.
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as location:
            session.location = location
            emit(
                ev="ready",
                udid=getattr(rsd, "udid", udid),
                ios=getattr(rsd, "product_version", None),
            )
            emit(ev="health", state="live")

            writer = asyncio.create_task(session.writer_loop())
            try:
                async for command in read_commands():
                    op = command.get("op")
                    seq = command.get("seq")

                    if op == "ping":
                        emit(ev="ok", seq=seq)

                    elif op == "set":
                        session.queue(command["lat"], command["lon"], seq)

                    elif op == "clear":
                        near = command.get("near")
                        try:
                            # Posting a point near the real one first speeds up
                            # reacquisition: otherwise the device stays stuck on
                            # the last simulated location for a long while.
                            if near:
                                await session.location.set(near["lat"], near["lon"])
                                await asyncio.sleep(0.4)
                            await session.location.clear()
                            session.last_sent = None
                            emit(ev="ok", seq=seq)
                        except Exception as exc:
                            emit(ev="error", seq=seq, code="clear_failed", msg=str(exc))

                    elif op == "bench":
                        try:
                            emit(ev="bench", seq=seq, **await session.measure(command.get("n", 30)))
                        except Exception as exc:
                            emit(ev="error", seq=seq, code="bench_failed", msg=str(exc))

                    elif op == "quit":
                        emit(ev="ok", seq=seq)
                        break

                    else:
                        emit(ev="error", seq=seq, code="unknown_op", msg=str(op))

                    if session.stopping.is_set():
                        break
            finally:
                session.stopping.set()
                session.wake.set()
                writer.cancel()
                try:
                    await writer
                except (asyncio.CancelledError, Exception):
                    pass

    emit(ev="health", state="idle")


def main():
    parser = argparse.ArgumentParser(description="Location simulation helper for Anole.")
    parser.add_argument("--udid", default=None, help="Target device; the first one found by default.")
    arguments = parser.parse_args()

    try:
        asyncio.run(serve(arguments.udid))
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        emit(ev="error", code=type(exc).__name__, msg=str(exc))
        emit(ev="health", state="lost", msg=str(exc))
        sys.exit(1)


if __name__ == "__main__":
    main()
