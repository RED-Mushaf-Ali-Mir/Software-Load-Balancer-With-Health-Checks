import asyncio

async def handle_client(reader , writer):
	addresss  = writer.get_extra_info("peername")
	print("Client Connected :" , addresss)
	
	data = await reader.read(1024)
	print("Client data :" , data.decode())
	
	await asyncio.sleep(1)
	
	writer.write (b"hello from server")
	await writer.drain()
	writer.close()
	await writer.wait_closed()
	print("writer closed")




async def main():

	server = await asyncio.start_server(handle_client , "127.0.0.1" , 9000)
	print("Async server listening on 127.0.0.1:9000")
	async with server:
		await server.serve_forever()
		
asyncio.run(main())
