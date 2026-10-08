"""Regression for connection bursts, subscription acknowledgements and full fanout."""
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import time
from support import Client, PASSWORD, Server


def main():
    server = Server()
    peers = []
    try:
        user = Client(server.port)
        user.post('/api/setup', {'name': 'Burst user', 'email': 'burst@example.test',
            'password': PASSWORD, 'account_name': 'Burst test'}, expected=201)

        def connect(_):
            peer = user.socket()
            try:
                peer.send({'type': 'subscribe', 'room_id': 1})
                assert peer.until('presence')['users'] == [user.user['id']]
                return peer
            except BaseException:
                peer.close()
                raise

        started = time.monotonic()
        failures = []
        with ThreadPoolExecutor(max_workers=50) as pool:
            for future in as_completed([pool.submit(connect, n) for n in range(1000)]):
                try:
                    peers.append(future.result())
                except Exception as error:
                    failures.append(str(error))
            assert not failures, failures[:10]
            for n in range(3):
                message = user.message(1, f'Complete delivery {n}')

                def receive(peer):
                    event = peer.until('message')
                    assert event['message']['id'] == message['id']
                    assert event['message']['plain'] == message['plain']

                list(pool.map(receive, peers))
        print(json.dumps({'connections': len(peers), 'complete_broadcasts': 3,
            'seconds': round(time.monotonic() - started, 3)}))
    finally:
        for peer in peers:
            peer.close()
        server.close()


if __name__ == '__main__':
    main()
