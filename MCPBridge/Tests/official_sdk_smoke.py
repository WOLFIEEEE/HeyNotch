#!/usr/bin/env python3
"""Use the official Python MCP client against the native binary and an in-memory broker."""
import argparse
import importlib.metadata
import json
from pathlib import Path
import tempfile
import threading
import uuid
import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from protocol_integration import Broker

async def run(binary):
    server=Broker(); threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='heynotch-official-mcp-') as temp:
            connection=Path(temp)/'connection.json'
            connection.write_text(json.dumps({'version':1,'endpoint':f'http://127.0.0.1:{server.server_port}','clientID':server.client_id,'token':server.token}))
            connection.chmod(0o600)
            parameters=StdioServerParameters(command=str(binary),args=['--connection',str(connection)])
            async with stdio_client(parameters) as (reader,writer):
                async with ClientSession(reader,writer) as session:
                    initialized=await session.initialize()
                    assert initialized.protocolVersion=='2025-11-25'
                    tools=await session.list_tools(); assert len(tools.tools)==9
                    context=await session.call_tool('get_context',{})
                    assert context.isError is False and context.structuredContent['ok'] is True
                    found=await session.call_tool('find_tasks',{'query':'café 👋','limit':1})
                    assert found.structuredContent['result']['arguments']['query']=='café 👋'
                    operation=str(uuid.uuid4())
                    created=await session.call_tool('create_task',{'operationID':operation,'listID':'fixture','title':'Official SDK fixture'})
                    assert created.isError is False
                    invalid=await session.call_tool('move_task',{'taskID':'missing operation and revision'})
                    assert invalid.isError is True
                    await session.send_ping()
            print(json.dumps({'officialPackage':'mcp','version':importlib.metadata.version('mcp'),
                              'protocolVersion':initialized.protocolVersion,'tools':len(tools.tools),
                              'checks':['initialize','list_tools','get_context','Unicode arguments','synthetic write','schema error result','ping','stdio shutdown']},indent=2))
    finally:
        server.shutdown();server.server_close()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=Path(__file__).resolve().parents[1]/'.build/debug/heynotch-mcp')
    args=parser.parse_args();anyio.run(run,args.binary.resolve())
