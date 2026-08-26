---
title: 'Step-by-Step Guide To Creating A TCP Server for Multiple Platforms'
summary: 'Guide to Writing a TCP Server in C for Different Operating Systems'
authors:
  - 'Adewole Caleb'
date: '2026-08-15'
topics:
  - 'C'
  - 'Networking Programming'
  - 'TCP'
  - 'Linux'
  - 'Windows'
  - 'Engineering'
type: 'Blog'
image: '![image](../../../blobs/cover32.webp)'
---
> Prerequisite - You should be familiar with how browsers and, the web work at the very least. This blog is written to teach what I learnt from my studies on network programming in C.

Yeah, Simple server in C, right? 😅 .

Of course, it is not simple, but it is simple enough to give you a glimpse into how browser-to-server communication implementation works under the hood of platforms like Nodejs. So, if you are curious, let's walk through it together

# Sockets

A socket is a communication medium or link between systems. Your computer has sockets that allow it to communicate with other computers. This is how your application receives all of its network data. Different platforms offer a few different socket application programming techniques (APIs), such as [**Berkley sockets (BSD Socket)**](https://en.wikipedia.org/wiki/Berkeley_sockets) or [**Winsock (Windows socket)**](https://en.wikipedia.org/wiki/Winsock). Historically, sockets were used for inter-process communication (IPC), which is important when processes need to communicate with each other.

Preparing a network program in C to be cross-platform for both Windows and Linux-based systems is important.

```c
#if defined(_WIN32)
	#ifndef _WIN32_WINNT
		#define _WIN32_WINNT 0x600
	#endif
	#include <winsock2.h>
	#include <ws2tcpip.h>
	#pragma comment(lib,"ws2_32.h")
	
	#define CLOSESOCKET(s) closesocket(s)
	#define ISVALIDSOCKET(s) ((s) != INVALID_SOCKET)
	#define GETSOCKETERRONO() (WSAGetLastError())
#else
	#include <sys/types.h>
	#include <sys/socket.h>
	#include <netinet/in.h>
	#include <arpa/inet.h>
	#include <netdb.h>
	#include <unistd.h>
	#include <errno.h>
#define SOCKET int
#define ISVALIDSOCKET(s) ((s) >= 0)
#define CLOSESOCKET(s) close(s)
#define GETSOCKETERRNO() (errno)
#endif
#if !defined(IPV6_V6ONLY)
	#define IPV6_V6ONLY 27
#endif
#include <stdio.h>
#include <string.h>
#include <time.h>

int main(int argc, char** argv) {
	 #if defined(_WIN32)
		WSDATA d;
		if (WSAStartup(MAKEWORD(2,2),&d)){
			fprintf(stder,"failed to initialize.\n");
			return 1;
		}
	#endif

	// code section setup

	#if defined(_WIN32)
		WSACleanup();
	#endif
	return 0;
}
```

Yeah, what is this, right?

Don't worry, I will explain soon.

You wouldn't do this in languages like PHP or JavaScript (Node), so why is it so difficult in C? It's because most of these underlying implementations are abstracted away in those languages, making them much simpler for programmers to use.

Implementation differs across platforms, so to ensure programs are cross-platform, we need to account for these differences. If you look closely at the code, you will find a `#if defined(_WIN32)` condition that sets up the library for the Windows platform. Otherwise, it specifies the libraries for [UNIX](https://en.wikipedia.org/wiki/Unix) or Linux machines. The selected library provides functionality to set up and configure sockets on both platforms. A macro definition in the header allows us to use different functions from Windows, UNIX, and Linux as if they are the same.

```c
#define CLOSESOCKET(s) closesocket(s)
#define ISVALIDSOCKET(s) ((s) != INVALID_SOCKET)
#define GETSOCKETERRONO() (WSAGetLastError())
```

The macros above are used on a Windows machine because they differ from how Unix functions are implemented and handle errors differently.

```c
#define SOCKET int    
#define ISVALIDSOCKET(s) ((s) >= 0)
#define CLOSESOCKET(s) close(s)
#define GETSOCKETERRNO() (errno)
```

Here is the Linux macro definition for the previous code. Windows and Linux handle socket errors differently and use different data types. To keep things consistent, we use macro definitions to ensure they work the same way on both platforms.

```c
#if defined(_WIN32)
	WSDATA d;
	if (WSAStartup(MAKEWORD(2,2),&d)){
		fprintf(stder,"failed to initialize.\n");
		return 1;
	}
#endif

//....
#if defined(_WIN32)
	WSACleanup();
#endif
return 0;
```

The above code ensures that socket programming on Windows is set up correctly when libraries are loaded and that proper cleanup occurs after termination.

## Types Of Sockets

There are two types of socket. Namely

1.  Connection-oriented socket e.g TCP
    
2.  Connectionless oriented socket e.g UDP
    

Connectionless might sound funny since we are dealing with connections, right? Let's take a closer look at these two to better understand how they work.

[**Transmission Control Protocol**](https://en.wikipedia.org/wiki/Transmission_Control_Protocol) is a **connection-oriented** protocol that guarantees the order of data transmission between parties, usually a client and a server. It ensures that no duplicate data packets are sent during transmission.

[**User Datagram Protocol**](https://en.wikipedia.org/wiki/User_Datagram_Protocol), on the other hand, is a connectionless protocol that does not ensure the order of data or care about redundant data packets.

Since we are dealing with TCP, we will use a few C functions to build our server. Here is a brief description of each function.

| **Function** | **Description** |
| --- | --- |
| `socket()` | Creates and initializes a new socket. |
| `bind()` | Associates a socket with a particular local IP address and port number. |
| `listen()` | Used on the server to cause a TCP socket to listen for new connections. |
| `accept()` | Used on the server to create a new socket for an incoming TCP connection. |
| `send()` | Used to send data with a socket. |
| `recv()` | Used to receive data with a socket. |
| `close()` | (Berkeley sockets) Used to close a socket. In the case of TCP, this also terminates the connection. |
| `closesocket()` | (Winsock sockets) Used to close a socket. In the case of TCP, this also terminates the connection. |
| `getnameinfo()` | Provides a protocol-independent manner of working with hostnames and addresses. |
| `getaddrinfo()` | Provides a protocol-independent manner of working with hostnames and addresses. |

As I said earlier, we created the macros above to help us with the differences in the function on each platform as shown in the table above.

## TCP Flow

So we can understand TCP's flow properly, we will assume the client in this case is our native browser.

A TCP client program must first know the address of the TCP server. This address is either entered directly by the user into the browser's address bar (e.g., [`http://abc.com`](http://example.com)) or obtained when the user clicks on a link. The browser, acting as the TCP client, then uses the `getaddrinfo()` function to convert this address into a `struct addrinfo` structure. Next, the client creates a socket with a call to `socket()`. To establish the new TCP connection, the client calls `connect()`. Once connected, the client can exchange data using `send()` and `recv()`.

A TCP server listens for connections on a specific port number and interface. First, the server program initializes a `struct addrinfo` structure with the appropriate IP address and port number for listening. Using the `getaddrinfo()` function helps ensure compatibility with both IPv4 and IPv6. The server then creates a socket by calling `socket()`. This socket is bound to the designated IP address and port using the `bind()` function. Also, this current socket, in particular, is with the server. Then we call `listen()` function to ensure the socket is in a listening state, and is ready for incoming connections. When a client attempts to connect, the server calls `accept()`, which waits for and then accepts the connection. Once a new connection is established, `accept()` returns a new socket that can be used to communicate with the client via `send()` and `recv()`. The original socket remains in the listening state and repeated calls to `accept()` allow the server to handle multiple clients simultaneously.

> The reason why we create another socket after the initial one before

With the flow out of the way, let's now see how we can implement a simple server with Hello World written back to the browser in this case

## Implementation

```c
printf("[LOG] Configuring local address...\n");
    
struct addrinfo hints;
memset(&hints,0,sizeof(hints));
hints.ai_family = AF_INET; // IPV4 version
hints.ai_socktype = SOCK_STREAM; // TCP Stream specification
hints.ai_flags = AI_PASSIVE;  // bind to the wildcard address - listen on any available network interface

struct addrinfo *bind_address;
getaddrinfo(0,"8090",&hints,&bind_address);
```

To create our server, we need to set up a socket for communication. In a typical backend server, like a Node.js server, this is usually handled by calling `app.listen("8080")`. However, we will be implementing what happens behind the scenes. In the code above, to set up a socket, we need to configure the address information for the server. The `addrinfo` struct allows us to do this. We initialize each field in the struct after setting the memory location of `hints` to zero using the `memset` function. We set the address to support IPv4 and specify that we are dealing with TCP stream packets using the `SOCK_STREAM` flag. To ensure all our network interfaces are listening, we use the `AI_PASSIVE` flag. The result of `getaddrinfo` is stored in the `bind_address` variable to confirm the address was properly resolved.

```c
printf("[INFO] Creating socket...\n");
SOCKET socket_listen;
socket_listen = socket(
bind_address->ai_family,
bind_address->ai_socktype,bind_address->ai_protocol);

if(!ISVALIDSOCKET(socket_listen)){
   fprintf(stderr,"[ERROR] socket() failed. (%d)\n",GETSOCKETERRNO());
   return 1;
}
```

Now, we create a socket using the resolved address information by calling the `socket(...)` function. This function returns either an `unsigned int` on Windows or an `int` on Linux. To ensure consistency across platforms, we set up macro definitions. The function returns one of these types after passing in the family type (IPv4 or IPv6), the type of socket (TCP stream), and the protocol resolved by `getaddrinfo(...)`.

We then check for the validity of the allocation of the return [`socket file descriptor (fd)`](https://en.wikipedia.org/wiki/File_descriptor) and error out via the global error variable `errno`

```c
// bind resolved address to socket 
printf("[INFO] Binding socket to local addres ...\n");
if (bind(socket_listen,bind_address->ai_addr,bind_address->ai_addrlen)){
   fprintf(stderr,"[ERROR] bind() failed. (%d)\n",GETSOCKETERRNO());
   return 1;
}
```

We now attempt to bind the created socket to the specified local IP address, in this case, `localhost:8090`, using the `bind` function. The `bind` function links the socket, identified by the `socket_listen` variable, with the address information provided by `bind_address->ai_addr` and its length `bind_address->ai_addrlen`. If the `bind` function returns `-1`, indicating an error, we print an error message to the standard error stream, including the specific socket error number retrieved by `GETSOCKETERRNO()`.

Next, we configure our socket to listen for maximum connections. If the number of connections exceeds this limit, all incoming connections are dropped, and we send an error back to the browser.

```c
int max_number_of_queued_connection = 10;
printf("[INFO] Listening ...\n");
if (listen(socket_listen,max_number_of_queued_connection) < 0){
  fprintf(stderr,"[ERROR] listen() failed. (%d)",GETSOCKETERRNO());
  return 1;
}
```

Now that we can listen for incoming connections, we create a storage address for the connecting client. Since our client address might be of type IPv4 or IPv6, we use the `sizeof` function to get the exact data size. We then accept the incoming connection with the `accept(...)` function, using the `socket_listen` The file descriptor specifies a pointer for our client address storage and data size.

```c
printf("[INFO] Waiting for connection..\n");
struct sockaddr_storage client_address;
socklen_t client_len = sizeof(client_address);
SOCKET socket_client = accept(socket_listen,(struct sockaddr*) &client_address, &client_len);
if (!ISVALIDSOCKET(socket_client)){
   fprintf(stderr,"[ERROR] accept() failed. (%d)\n",GETSOCKETERRNO());
   return 1;
}
```

To print information about the connecting client, in this case, our browser, we create a buffer of 100 bytes and use `getnameinfo` to write into it.

```c
printf("[INFO] Client is connected...");
char address_buffer[100];
getnameinfo((struct sockaddr*)&client_address,
client_len, address_buffer,sizeof(address_buffer),0,0,NI_NUMERICHOST);
printf("%s\n",address_buffer);
```

With the code below, we handle receiving a request from a client socket and sending a response back. We declare a buffer `request` with a size of 1024 bytes and attempt to receive data from `socket_client` into this buffer using the `recv` function. The number of bytes received is stored in `bytes_received`. If `recv` returns a negative value, indicating an error, it prints an error message to the standard error stream with the specific socket error number obtained from `GETSOCKETERRNO()`. If the data is received successfully, we print an informational message showing the number of bytes received, followed by the received data.

```c
printf("[INFO] Reading request...\n");    
char request[1024];    
int bytes_received = recv(socket_client, request, 1024, 0);    
if(bytes_received < 0) {
   fprintf(stderr,"[ERROR] recv() failed. (%d)\n",GETSOCKETERRNO());
   return 1;
}
printf("[INFO] Received %d bytes.\n", bytes_received);
```

Now, we are ready to send our server response.

To do this, we construct our standard header response with `\r\n` at the end to separate the header from the actual response body. We then send it to the browser using the `send(...)` function.

```c
const char* response = "HTTP/1.1 200 OK\r\n"
        "Connection: close\r\n"
        "Content-Type: text/plain\r\n\r\n"
        "Local Time is: ";
int bytes_sent = send(socket_client,response,strlen(response),0);
if(bytes_sent < 0) {
   fprintf(stderr,"[ERROR] send() failed. (%d)\n",GETSOCKETERRNO());
   return 1;
}
printf("[INFO]Sent %d of %d bytes.\n",bytes_sent,(int)strlen(response));
```

We can then write our response to the body and send it out, similar to the previous code snippet. This allows the user to view the response in the browser.

Once this is done, we can close our socket with `CLOSESOCKET(...)` to avoid leakage.

```c
char *hello_msg = "Hello World!!!";
bytes_sent = send(socket_client,hello_msg,strlen(hello_msg),0);
if(bytes_sent < 0) {
   fprintf(stderr,"[ERROR] send() failed. (%d)\n",GETSOCKETERRNO());
    return 1;
}
printf("[INFO] Sent %d of %d bytes.\n",bytes_sent,(int)strlen(time_msg));
printf("[INFO] Closing connection...\n");

CLOSESOCKET(socket_listen);
```

After writing this whole code we can then compile the code with the command : `gcc <file_name>.c -o <object_name>` and then run it with `./<object-name>` . With this when you run it you should get something similar to this on your console.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1717272297624/9e6e4ce3-6e79-4756-819d-a5fc73212bc0.png align="center")

And on your browser, you should get `hello world` when you connect via `http://localhost:8090` in your search bar.

In summary, this article tries to show you that there is more to just the `app.listen("8080")` that you usually see and a lot of things have been abstracted away from you so you don't have to deal with them. Digging deep is important in computing so stay curious.

Resources:  
\- [https://en.wikipedia.org/wiki/Winsock](https://en.wikipedia.org/wiki/Winsock)  
\- [https://en.wikipedia.org/wiki/Berkeley\_sockets](https://en.wikipedia.org/wiki/Berkeley_sockets)  
\- **hands-on network programming with C by Lewis Van Winkle**
