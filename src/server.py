import socket

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(("127.0.0.1", 9000))
server.listen()
print("Server listening on 127.0.0.1:9000")

connection, address = server.accept()
print("Client connected:", address)

data = connection.recv(1024)
print("Client said:", data.decode())

connection.sendall(b"Hello from the server!")
connection.close()
server.close()
