#!/usr/bin/env python3
"""Hermetic forwarding checks; no VMs or services are started."""
import importlib.util
from pathlib import Path
import socket
import threading
import unittest
from unittest.mock import patch
import tempfile
import io
import json

spec = importlib.util.spec_from_file_location("relay", Path(__file__).resolve().parents[1] / "bin/hypeman-relay.py")
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

class ForwardingTest(unittest.TestCase):
    def test_tcp_bidirectional_and_close(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        def echo():
            connection, _ = server.accept()
            with connection:
                data = connection.recv(1024)
                connection.sendall(b"reply:" + data)
        worker = threading.Thread(target=echo)
        worker.start()
        forward = relay.Forward(0, "127.0.0.1", server.getsockname()[1])
        try:
            with socket.create_connection(forward.socket.getsockname(), timeout=2) as client:
                client.sendall(b"websocket payload")
                self.assertEqual(client.recv(1024), b"reply:websocket payload")
        finally:
            forward.close()
            worker.join(timeout=2)
            server.close()
        self.assertFalse(forward.thread.is_alive())

    def test_udp_keeps_two_live_clients_separate(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("127.0.0.1", 0))
        server.settimeout(2)
        def echo():
            for _ in range(2):
                data, address = server.recvfrom(1024)
                server.sendto(b"echo:" + data, address)
        worker = threading.Thread(target=echo)
        worker.start()
        forward = relay.Forward(0, "127.0.0.1", server.getsockname()[1], udp=True)
        clients = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for _ in range(2)]
        try:
            for index, client in enumerate(clients):
                client.settimeout(2)
                client.sendto(str(index).encode(), forward.socket.getsockname())
            for index, client in enumerate(clients):
                self.assertEqual(client.recv(1024), b"echo:" + str(index).encode())
        finally:
            for client in clients:
                client.close()
            forward.close()
            worker.join(timeout=2)
            server.close()
        self.assertFalse(forward.thread.is_alive())

class ReconciliationTest(unittest.TestCase):
    def test_owned_forwarding_changes_incarnation_and_ignores_foreign_guests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'connection.json').write_text('{"baseUrl":"http://127.0.0.1:4973"}')
            (root / 'token').write_text('test-token')
            tags = {'dev.agentbrowse.managed': 'true', 'dev.agentbrowse.role': 'kernel-browser',
                    'dev.agentbrowse.hypeman.spec': '1', 'dev.agentbrowse.slot': '3', 'dev.agentbrowse.port-offset': '2000'}
            guests = [{'id': 'first', 'state': 'Running', 'network': {'ip': '192.168.65.2'}, 'tags': tags},
                      {'id': 'foreign', 'tags': {}}]
            def response(*args, **kwargs):
                return io.StringIO(json.dumps(guests))
            service = relay.Relay(root)
            with patch.object(relay.urllib.request, 'urlopen', side_effect=response), patch.object(relay, 'Forward') as forward:
                service.sync()
                self.assertEqual(forward.call_count, 3)
                self.assertEqual(set(service.forwards), {(11225, False), (20083, False), (58003, True)})
                service.sync()
                self.assertEqual(forward.call_count, 3)
                guests[0]['id'] = 'replacement'
                guests[0]['network']['ip'] = '192.168.65.3'
                service.sync()
                self.assertEqual(forward.call_count, 6)
                self.assertEqual(forward.return_value.close.call_count, 3)
                guests[0]['state'] = 'Stopped'
                service.sync()
                self.assertEqual(service.forwards, {})
                self.assertEqual(forward.return_value.close.call_count, 6)

if __name__ == "__main__":
    unittest.main()
