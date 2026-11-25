"""Owned SDK生命周期夹具，不冒充独立第三方服务；协议由固定安装的官方SDK实现。"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import threading
import uvicorn
from mcp.server.mcpserver import MCPServer

async def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--transport',choices=['stdio','http'],required=True)
    parser.add_argument('--marker-dir',type=Path,required=True)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    marker=args.marker_dir.resolve()
    if not marker.is_relative_to((root/'.local/interop').resolve()) or marker.exists():raise ValueError('Use a fresh owned marker directory')
    marker.mkdir(parents=True,mode=0o700)
    state={'started':0,'finalized':0,'completed':0}
    lock=threading.Lock()
    def publish():
        path=marker/'state.tmp';path.write_text(json.dumps(state));path.replace(marker/'state.json')
    server=MCPServer('KeyDock owned lifecycle fixture')
    @server.tool()
    async def slow() -> dict[str,int]:
        with lock:state['started']+=1;publish()
        try:
            await asyncio.sleep(60)
            with lock:state['completed']+=1;publish()
            return dict(state)
        finally:
            with lock:state['finalized']+=1;publish()
    @server.tool()
    def snapshot() -> dict[str,int]:
        with lock:return dict(state)
    if args.transport=='stdio':await server.run_stdio_async()
    else:
        # 只监听owned loopback端口；不更改SDK协议或服务端schema。
        port=int(os.environ.get('PORT','0'))
        app=server.streamable_http_app(host='127.0.0.1')
        await uvicorn.Server(uvicorn.Config(app,host='127.0.0.1',port=port)).serve()

if __name__=='__main__':asyncio.run(main())
