import socket

client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.connect(("127.0.0.1", 9000))
print("Connected to the server")

client.sendall(b"Hello from the client!")
data = client.recv(1024)
print("Server replied:", data.decode())
client.close()
