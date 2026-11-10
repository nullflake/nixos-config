"""Reconcile zapret against NetworkManager connection attempts and VPN state."""

import asyncio
import contextlib
import logging
import os
import socket
import sys

from dbus_fast import BusType, Message, MessageType
from dbus_fast.aio import MessageBus
from dbus_fast.errors import DBusFastError

logger = logging.getLogger(__name__)

NM = "org.freedesktop.NetworkManager"
NM_PATH = "/org/freedesktop/NetworkManager"
ACTIVE = NM + ".Connection.Active"
DEVICE = NM + ".Device"
PROPERTIES = "org.freedesktop.DBus.Properties"
DBUS = "org.freedesktop.DBus"
SYSTEMD = "org.freedesktop.systemd1"
SYSTEMD_PATH = "/org/freedesktop/systemd1"
RETRY_SECONDS = 2
QUERY_TIMEOUT = 5


class ChangedDuringQuery(Exception):
    pass


class DBusCallError(RuntimeError):
    def __init__(self, member, error_name, body):
        self.error_name = error_name
        super().__init__(f"{member}: {error_name}: {body}")


class Guard:
    def __init__(self, bus):
        self.bus = bus
        self.changed = asyncio.Event()
        self.generation = 0

    def on_message(self, message):
        if message.message_type != MessageType.SIGNAL:
            return
        relevant = False
        if message.interface == DBUS and message.member == "NameOwnerChanged":
            relevant = message.body[0] == NM
        elif message.path and (
            message.path == NM_PATH or message.path.startswith(NM_PATH + "/")
        ):
            if (
                message.interface == PROPERTIES
                and message.member == "PropertiesChanged"
            ):
                interface, changed, invalidated = message.body
                watched = {
                    NM: {"ActiveConnections", "Devices", "Startup", "State"},
                    ACTIVE: {"State", "Type", "Vpn", "Devices"},
                    DEVICE: {"State", "Interface", "DeviceType"},
                }.get(interface, set())
                relevant = bool(watched.intersection(set(changed) | set(invalidated)))
            elif message.member in {"StateChanged", "DeviceAdded", "DeviceRemoved"}:
                relevant = True
        if relevant:
            self.generation += 1
            self.changed.set()

    async def call(self, destination, path, interface, member, signature="", body=None):
        async with asyncio.timeout(QUERY_TIMEOUT):
            reply = await self.bus.call(
                Message(
                    destination=destination,
                    path=path,
                    interface=interface,
                    member=member,
                    signature=signature,
                    body=body or [],
                )
            )
        if reply.message_type == MessageType.ERROR:
            raise DBusCallError(member, reply.error_name, reply.body)
        return reply.body

    async def subscribe(self):
        self.bus.add_message_handler(self.on_message)
        for rule in (
            f"type='signal',sender='{NM}',path_namespace='{NM_PATH}'",
            (
                f"type='signal',sender='{DBUS}',interface='{DBUS}',"
                f"member='NameOwnerChanged',arg0='{NM}'"
            ),
        ):
            await self.call(
                DBUS, "/org/freedesktop/DBus", DBUS, "AddMatch", "s", [rule]
            )

    async def properties(self, owner, path, interface):
        (values,) = await self.call(owner, path, PROPERTIES, "GetAll", "s", [interface])
        return {key: variant.value for key, variant in values.items()}

    async def can_start(self):
        # Bind all reads to one NM instance. Missing objects/properties, timeouts and
        # concurrent changes invalidate the snapshot rather than implying no VPN.
        generation = self.generation
        async with asyncio.timeout(QUERY_TIMEOUT):
            (owner,) = await self.call(
                DBUS, "/org/freedesktop/DBus", DBUS, "GetNameOwner", "s", [NM]
            )
            manager = await self.properties(owner, NM_PATH, NM)
            if manager["Startup"] or manager["State"] == 0:
                return False
            connections = await asyncio.gather(
                *(
                    self.properties(owner, path, ACTIVE)
                    for path in manager["ActiveConnections"]
                )
            )
            devices = await asyncio.gather(
                *(self.properties(owner, path, DEVICE) for path in manager["Devices"])
            )
        if generation != self.generation:
            raise ChangedDuringQuery
        for connection in connections:
            # ActiveConnection exists during activation, including before tunX exists.
            # State 4 is fully deactivated; unknown (0) remains blocked.
            if (
                connection["Vpn"] or connection["Type"] in {"vpn", "wireguard", "tun"}
            ) and connection["State"] != 4:
                return False
        for device in devices:
            # Retain protection for externally created Proton/OpenVPN interfaces.
            # DeviceType 29 is WireGuard. Only unavailable/idle devices are safe;
            # unmanaged/unknown and failed devices still being cleaned up block.
            if (
                device["Interface"].startswith(("proton", "tun"))
                or device["DeviceType"] == 29
            ) and device["State"] not in {20, 30}:
                return False
        return True

    async def set_running(self, allowed):
        # A start must never replace a pending manual stop of the guard dependency.
        # A stop must replace pending starts, including ones waiting in ExecCondition.
        try:
            await self.call(
                SYSTEMD,
                SYSTEMD_PATH,
                SYSTEMD + ".Manager",
                "StartUnit" if allowed else "StopUnit",
                "ss",
                ["zapret.service", "fail" if allowed else "replace"],
            )
        except DBusCallError as error:
            if (
                allowed
                and error.error_name
                == "org.freedesktop.systemd1.TransactionIsDestructive"
            ):
                # A stop is still pending. Keep it intact and let the next
                # reconciliation retry, including during a manual monitor stop.
                logger.debug("Deferring zapret start until the pending job completes")
                return
            raise

    async def watch(self):
        stop_first = True
        previous = None
        while True:
            notify_watchdog()
            if stop_first:
                await self.set_running(False)
            self.changed.clear()
            query = asyncio.create_task(self.can_start())
            change = asyncio.create_task(self.changed.wait())
            try:
                await asyncio.wait((query, change), return_when=asyncio.FIRST_COMPLETED)
                if self.changed.is_set():
                    # Interrupt slow queries on a transition; stop before reading again.
                    stop_first = True
                    continue
                try:
                    allowed = query.result()
                except ChangedDuringQuery:
                    allowed = False
                except (OSError, DBusFastError, DBusCallError, KeyError) as error:
                    logger.warning(
                        "VPN state unavailable; stopping zapret: %s",
                        str(error) or type(error).__name__,
                    )
                    allowed = False
            finally:
                for task in (query, change):
                    task.cancel()
                await asyncio.gather(query, change, return_exceptions=True)

            # Draining the cancelled waiter can itself deliver another NM signal.
            allowed = allowed and not self.changed.is_set()
            await self.set_running(allowed)
            if allowed != previous:
                logger.info("zapret %s", "allowed" if allowed else "blocked")
                previous = allowed
            try:
                await asyncio.wait_for(self.changed.wait(), RETRY_SECONDS)
                stop_first = True
            except TimeoutError:
                # Periodic fresh reads recover from missed events and transient errors,
                # including an ExecCondition that skipped a previous start attempt.
                stop_first = False


def notify_watchdog():
    address = os.environ.get("NOTIFY_SOCKET")
    if address:
        if address.startswith("@"):
            address = "\0" + address[1:]
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as connection:
            connection.sendto(b"WATCHDOG=1", address)


async def main(check):
    bus = MessageBus(bus_type=BusType.SYSTEM, auth_timeout=QUERY_TIMEOUT)
    connected = False
    try:
        async with asyncio.timeout(QUERY_TIMEOUT):
            await bus.connect()
        connected = True
        guard = Guard(bus)
        await guard.subscribe()
        if check:
            return 0 if await guard.can_start() else 1
        watcher = asyncio.create_task(guard.watch())
        disconnected = asyncio.create_task(bus.wait_for_disconnect())
        try:
            done, _ = await asyncio.wait(
                (watcher, disconnected), return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                task.result()
            raise ConnectionError("System bus disconnected")
        finally:
            watcher.cancel()
            disconnected.cancel()
            await asyncio.gather(watcher, disconnected, return_exceptions=True)
    finally:
        bus.disconnect()
        # Close the transport before asyncio.run closes the event loop.
        if connected:
            with contextlib.suppress(OSError, DBusFastError, asyncio.CancelledError):
                async with asyncio.timeout(1):
                    await bus.wait_for_disconnect()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        sys.exit(asyncio.run(main(check="--check" in sys.argv[1:])))
    except (OSError, DBusFastError, DBusCallError, KeyError) as error:
        logger.error("VPN guard failed: %s", error)
        sys.exit(2)
