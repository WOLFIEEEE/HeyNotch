#!/usr/bin/env python3
"""Exercise the native stdio binary against a synthetic loopback broker; no app data."""
import argparse
import http.server
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time
import uuid

class Broker(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.mode = 'normal'
        self.calls = []
        self.request_paths = []
        self.operations = {}
        self.token = 'fixture_' + uuid.uuid4().hex
        self.client_id = str(uuid.uuid4())
        self.redirect_url = ''

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        server = self.server
        server.request_paths.append(self.path)
        if self.path != '/v1/command' or self.headers.get('Authorization') != 'Bearer ' + server.token or self.headers.get('X-HeyNotch-Client') != server.client_id:
            self.send_error(403); return
        assert self.headers.get('Content-Type') == 'application/json'
        assert self.headers.get('Origin') is None and self.headers.get('Transfer-Encoding') is None
        count = int(self.headers['Content-Length']); assert count <= 65536
        payload = json.loads(self.rfile.read(count)); server.calls.append(payload)
        mode = server.mode
        if mode == 'disconnect':
            self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
        if mode == 'redirect':
            self.send_response(307); self.send_header('Location', server.redirect_url); self.send_header('Content-Length', '0'); self.end_headers(); return
        if mode == 'oversized':
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(2097153)); self.end_headers(); return
        if mode == 'denied':
            self.send_response(403); self.send_header('Content-Length', '0'); self.end_headers(); return
        if mode == 'invalid':
            raw = b'{"ok":true,"result":null}'
        else:
            tool, arguments = payload['tool'], payload['arguments']
            if mode == 'slow' and tool == 'create_task':
                time.sleep(.25)
                server.operations[arguments['operationID']] = {'operationID': arguments['operationID'], 'status': 'succeeded'}
            if tool == 'get_operation':
                result = server.operations.get(arguments['operationID'], {'status': 'uncertain'})
            elif mode == 'echo_secret':
                result = {'echo': server.token}
            else:
                result = {'tool': tool, 'arguments': arguments, 'fixture': True}
            value = {'ok': False, 'error': {'code': 'conflict', 'message': 'Refresh the task revision.'}} if mode == 'business_error' else {'ok': True, 'result': result}
            raw = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

class Client:
    def __init__(self, binary, connection):
        self.process = subprocess.Popen([str(binary), '--connection', str(connection)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.buffer = b''
        self.sequence = 0
    def send(self, value):
        self.process.stdin.write(json.dumps(value, ensure_ascii=False).encode() + b'\n')
    def read(self, timeout=3):
        until = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            ready, _, _ = select.select([self.process.stdout], [], [], max(0, until-time.monotonic()))
            if not ready:
                raise TimeoutError('No protocol response')
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError('Bridge exited before protocol response')
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)
    def request(self, method, params=None):
        self.sequence += 1
        value = {'jsonrpc':'2.0', 'id':self.sequence, 'method':method}
        if params is not None: value['params'] = params
        self.send(value)
        result = self.read(); assert result['id'] == self.sequence
        return result
    def initialize(self):
        value = self.request('initialize', {'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'fixture','version':'1'}})
        assert value['result']['protocolVersion'] == '2025-11-25'
        self.send({'jsonrpc':'2.0','method':'notifications/initialized'})
    def call(self, name, arguments=None):
        return self.request('tools/call', {'name':name,'arguments':arguments or {}})['result']
    def stop(self):
        self.process.stdin.close(); self.process.wait(timeout=3)
        errors = self.process.stderr.read()
        assert self.process.returncode == 0
        return errors

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path(__file__).resolve().parents[1]/'.build/debug/heynotch-mcp')
    args=parser.parse_args()
    server=Broker(); thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    checks=[]
    try:
        with tempfile.TemporaryDirectory(prefix='heynotch-mcp-fixture-') as temp:
            connection=Path(temp)/'connection.json'
            connection.write_text(json.dumps({'version':1,'endpoint':f'http://127.0.0.1:{server.server_port}','clientID':server.client_id,'token':server.token}))
            connection.chmod(0o600)
            client=Client(args.binary,connection)
            assert client.request('tools/list')['error']['code']==-32002
            client.initialize()
            assert len(client.request('tools/list')['result']['tools'])==9
            assert client.call('get_context')['structuredContent']['result']['fixture'] is True
            checks.append('initialize/lifecycle/catalog/authorized HTTP headers')
            result=client.call('find_tasks',{'query':'café 👋 नमस्ते','limit':1})
            assert result['structuredContent']['result']['arguments']['query']=='café 👋 नमस्ते'
            assert json.loads(result['content'][0]['text'])==result['structuredContent']
            checks.append('UTF-8 and matching structured/text content')
            before=len(server.calls)
            assert client.call('move_task',{})['isError'] is True
            assert len(server.calls)==before
            checks.append('schema failure never forwarded')
            args_write={'operationID':str(uuid.uuid4()),'listID':'fixture','title':'Synthetic only'}
            server.mode='business_error'
            assert client.call('create_task',args_write)['structuredContent']['error']['code']=='conflict'
            server.mode='disconnect'
            assert client.call('create_task',args_write)['structuredContent']['error']['code']=='write_outcome_unknown'
            assert client.call('get_context')['structuredContent']['error']['code']=='broker_unavailable'
            checks.append('business errors and uncertain write outcome without retry')
            server.mode='redirect'; server.redirect_url=f'http://127.0.0.1:{server.server_port}/redirect-target'
            before=len(server.calls); paths_before=len(server.request_paths)
            assert client.call('get_context')['isError'] is True
            assert len(server.calls)==before+1 and len(server.request_paths)==paths_before+1
            checks.append('redirect not followed')
            server.mode='oversized'
            assert client.call('get_context')['isError'] is True
            server.mode='invalid'
            assert client.call('get_context')['isError'] is True
            server.mode='denied'
            assert client.call('get_context')['structuredContent']['error']['code']=='access_denied'
            checks.append('bounded/invalid responses and denied credentials')
            server.mode='echo_secret'
            assert server.token not in json.dumps(client.call('get_context'))
            checks.append('credential redaction even in broker echo')
            server.mode='slow'; client.sequence+=1; cancelled_id=client.sequence
            client.send({'jsonrpc':'2.0','id':cancelled_id,'method':'tools/call','params':{'name':'create_task','arguments':args_write}})
            until=time.monotonic()+2
            while not any(c['tool']=='create_task' and c['arguments']==args_write for c in server.calls[-1:]):
                assert time.monotonic()<until;time.sleep(.01)
            client.send({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':cancelled_id}})
            time.sleep(.35)
            server.mode='normal'
            outcome=client.call('get_operation',{'operationID':args_write['operationID']})
            assert outcome['structuredContent']['result']['status']=='succeeded'
            checks.append('cancel suppresses reply while committed operation can be reconciled')
            before=len(server.calls)
            large={'operationID':str(uuid.uuid4()),'listID':'fixture','title':'Large body','notes':'\n'*40000}
            assert client.call('create_task',large)['structuredContent']['error']['code']=='request_too_large'
            assert len(server.calls)==before
            checks.append('encoded HTTP body bound before transmission')
            errors=client.stop();assert server.token.encode() not in errors
            checks.append('EOF shutdown and no token on stderr')
    finally:
        server.shutdown();server.server_close()
    print(json.dumps({'passed':len(checks),'checks':checks},indent=2))

if __name__=='__main__':
    main()
