import asyncio, sys
sys.path.insert(0, "src")
from proxy import Backend, check_once

async def run():
    print("9001 (running):", await check_once(Backend("127.0.0.1", 9001), 1.0))
    print("9999 (nothing there):", await check_once(Backend("127.0.0.1", 9999), 1.0))

asyncio.run(run())
