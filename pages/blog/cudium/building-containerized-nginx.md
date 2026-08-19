---
title: 'Building Containerized Nginx'
summary: 'A guide to building a containerized Nginx load balancer/API gateway/reverse proxy'
authors:
  - 'Cudium'
date: '2026-08-19'
topics:
  - 'Engineering'
  - 'Infrastructure'
  - 'Nginx'
  - 'Docker'
type: 'Blog'
image: '![image](../../../blobs/cover13.png)'
highlight: purple
---

# Building Containerized Nginx

A guide to building a containerized Nginx load balancer/API gateway/reverse proxy

## Introduction

> PS - The title will be a bit too cumbersome should we add all the functionality the build supports Also the pronoun "we" means I and the CTO

It was December last year, the clock was ticking. Another delivery is to be fulfilled. If you are wondering what it was? ...it was a load balancer / API gateway / reverse proxy waiting to be cooked 🔥.

A load balancer, from the name, is a combination of two keywords **load** and **balancer**. The load means requests while the balancer means an effective distributor. A load balancer is just any system that distributes the load in this scenario - a request made by the client which may be via a browser, or an application on a phone in an effective way to another system typically the backend server handling the request or fulfilling the other.

Nah, that was too basic, right? Let's crank it up a notch technically.

A load balancer is a device that sits right in between a user (client) and a server group (sets of servers) and acts as an invisible facilitator (according to AWS's definition) ensuring equal usage of resources by the servers in the group. Well in essence, load balancing is the process of distributing a set of tasks or requests over a set of resources (computing units), to make their overall processing more efficient and also to optimise response time by avoiding unevenly overloading some compute nodes while other compute nodes are left idle.

Back to the Christmas build conversation, we needed to integrate a new third-party provider. Initially, we allowed direct integration but in this case, things were different, the third party also used a different platform which requires a direct registration of our service IP address which cannot be changed without some setbacks. This led to a conversation with my CTO to figure out a way to leverage our deployment platform to avoid unnecessary costs from using AWS load balancing instances in summary avoid complexity and KISS (keep it simple ) lol.

To do this, we highlighted a couple of requirements which were:

1.  Running a load balancer at a reduced cost
    
2.  Opting in for auto-scaling
    
3.  Allowing request routing to necessary services
    
4.  An API gateway and proxy for all access to our platform
    
5.  An extensible application that can use things offered freely by Nginx
    

If you are wondering why we didn't use an out-of-the-box solution, well we didn't because we need to avoid bleeding out of cash just by running an overly complicated service for our use case.

Christmas morning, I think I had just finished going through the [Nginx documentation](https://docs.nginx.com/nginx/admin-guide/load-balancer/http-load-balancer/) and also checked out [Hussein's course](https://www.udemy.com/course/nginx-crash-course/?couponCode=KEEPLEARNING) on Nginx but since I don't understand well until I can figure out why the internals of the system works the way it does. I took my time to study the brief internals of Nginx. Let's take a quick look together so we can get a better understanding of the conf files later.

### Nginx - a Proxy / API gateway / Load-balancer

Nginx acts as a web server capable of serving web content and can also act as a reverse proxy, load balancer for backend routing, caching layer and API gateway.

> An API Gateway is a server that acts as an API front-end, receiving API requests, enforcing throttling and security policies, passing requests to the back-end service, and then passing the response back to the requester. It acts as an entry point for one or multiple micro-services, providing a unified interface to clients. A proxy / API gateway / load-balancer should not be blocking but as efficient as possible so that another backend server can scale independently but with additional cost.

NGINX has a concept of frontend end (client side) and back end (server side). It has layer 4/7 (Transport layer) of the [OSI model](https://en.wikipedia.org/wiki/OSI_model) support. NGINX spins up a worker process per CPU core by default. When NGINX reverse proxy starts it creates one thread per CPU core and these worker threads do the heavy lifting. The number of worker threads is configurable but NGINX recommends one thread per CPU core to avoid context switching and cache thrashing.

Since this article is more about how to use docker and nginx to build a full-fledged proxy and API gateway and load-balancer. You can check out this [link](https://docs.nginx.com/nginx/admin-guide/) for more info on nginx but before that let's have a quick look at what docker is.

### Docker - a Containerizer

Docker is a powerful tool that allows you to create, deploy, and run applications in containers. These containers are lightweight, standalone, and executable packages that include everything needed to run a piece of software: the code, runtime, libraries, and dependencies. Essentially, Docker containers act like mini virtual machines but are much more efficient and faster.

Imagine you're setting up a big application that includes a user interface (UI), a database, and several microservices, each of which requires different programs and dependencies (like Java, Node.js, or Python). Without Docker, you'd need to manually install and configure all these components on a new server, which could take days and be prone to errors.

With Docker, you can package each component of your application into a separate container, complete with all its dependencies. You then simply deploy these containers to the server. The setup is automated and takes minutes instead of days, and you can be confident that everything will work correctly. The biggest advantage of dockers is to ability to have the same setup everywhere and also you can very quickly bootstrap the whole infrastructure. And containers can build very quickly.

You can check this [link](https://docs.docker.com/get-started/overview/) for more info on docker

I figured explaining what NGINX and docker stood for would give you an insight into what we built eventually. Anyway, let's get into it 🚀

### XCRUX

xcrux provides Nginx configurations for setting up an API gateway, load balancer, and reverse proxy. It was designed to help us efficiently manage, secure, and optimise API requests in our backend application while keeping all our requirements in check. We opted in to support the following features:

*   API Gateway: Direct incoming API requests to appropriate backend services.
    
*   Load Balancer: Distribute traffic across multiple backend servers for improved performance and reliability.
    
*   Reverse Proxy: Handle requests on behalf of backend servers, providing additional features such as SSL termination.
    

One key thing we strived for was the project file organisation to cater for extensibility. We divided the project into the following:

1.  client configuration
    
2.  location groups configuration - for each backend server upstream
    
3.  static file definitions
    

By default, Nginx comes with its very own configuration spec which is loaded on startup. This configuration is used to set up how the master-worker process of nginx will operate in terms of load balancing, request forwarding etc.

Using simple examples, I will give an explanatory approach to how this works using a couple of Xcrux examples (not exact but just configuration syntax )

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716464466097/baaf5e0e-95c2-4d88-a914-c45aed2de567.png align="center")

One thing about Nginx is the fact that it runs a master-worker process. However, it allows developers to specify how the processes should function. If you look closely at the configuration spec above you will see that one can specify the number of workers to run to handle requests. Less I forget, the Nginx configuration is divided into a bunch of directives, the one we are currently in is called the **global directive** and in this, an error log configuration is set up to help when debugging requests and response logs.

The next directive is the **event directive**, which specifies things like the queue logic to use depending on the operating system also you can specify the number of incoming requests the workers can handle. All connection configurations are set here

> directives act as “containers” that group together related directives, enclosing them in curly braces ( `{}` ); these are often referred to as *blocks*

Read more on directives [here](https://docs.nginx.com/nginx/admin-guide/basic-functionality/managing-configuration-files/)

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716467089271/8af389de-a4f0-4746-b8fc-c27667671eb7.png align="center")

To specify the protocol we need, Nginx allows us to use an **HTTP directive**, which allows us to set up all HTTP-related configurations that will affect all virtual servers. For example, if you need to use SSL certification, specify a security protocol to support HTTPs you can do that here.

Looking at the configuration below specifies the following :

1.  How logging should be handled in the server
    
2.  The port configuration for the servers and when to timeout for every request
    
3.  Rate limiting specification for each request.
    
4.  Proxy configuration which is the reason why the server now can act as a reverse proxy too. Each command e.g. `proxy_connect_timeout` is a module directive for the server block which specifies when the request is proxied should timeout.
    

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716466714213/d7c9ef93-40a3-470f-9e7f-f1e3c1028255.png align="center")

> The configuration above depends on the use-case scenario, one great way to know what works is to try out each directives in bits , learn about them individually and then how they affect a block directive if included

You might have noticed a couple of includes in the image above, well that is how to ensure extensibility as we can now deal with how we handle request loads via HTTP. One thing to note is that the Nginx HTTP server also supports UDP protocol but we did not need that for our use-case

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716466784386/e0ea14a4-33a7-4186-9794-03dcf3b0245d.png align="center")

To track if our server is up and running and not down since Nginx allows us to serve static content, we included a couple of pages to keep tabs on the server's health and error pages in case of an invalid request.

Now back to the include command which allows us to separate configuration into separate files. We set up configuration into global client and specific location server folders grouping to allow configuration for each location server that we run.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716466859311/98d5c8a7-8de0-46ee-beed-0e13c4b036e6.png align="center")

To handle each HTTP server upstream, which is where all requests are proxied to, we separated all locations for our server and handled the configuration individually, for example in this case for the configuration above, this Nginx location configuration block is designed to handle requests that start with `/location-path-prefix/` and proxy them to a group of backend servers (denoted as [`http://example-servers`](http://example-servers)). Here's a summary of what each directive does:

1.  **Proxy Headers:**
    
    *   `proxy_set_header Host $host;`: Sets the `Host` header in the proxied request to the original host from the client request.
        
    *   `proxy_set_header X-Original-URI $request_uri;`: Adds the original request URI to the header, which can be useful for the backend to know the initial request path.
        
    *   `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`: Adds the client's IP address to the `X-Forwarded-For` header, which helps the backend know the client's original IP.
        
    *   `proxy_set_header Upgrade $http_upgrade;` and `proxy_set_header Connection "upgrade";`: These headers support WebSocket connections by handling the `Upgrade` request header and setting the `Connection` header to "upgrade".
        
    *   `proxy_set_header X-Proxy-Server '';`: Sets an empty `X-Proxy-Server` header, which might be used for custom logging or debugging purposes on the backend.
        
2.  **Proxy Pass:**
    
    *   `proxy_pass`[`http://example-servers`](http://example-servers)`;`: Forwards the request to the backend servers identified by [`http://example-servers`](http://example-servers).
        
3.  **Error Handling and Retries:**
    
    *   `proxy_next_upstream error timeout http_504 non_idempotent;`: Specifies conditions (error, timeout, HTTP 504, non-idempotent) under which the request should be retried with the next server in the upstream group.
        
    *   `proxy_next_upstream_tries 3;`: Limits the number of retry attempts to 3.
        
    *   `proxy_next_upstream_timeout 15s;`: Sets a timeout of 15 seconds for each retry attempt.
        
4.  **Client Request Limits:**
    
    *   `client_max_body_size 2m;`: Limits the maximum size of the client request body to 2 megabytes.
        
5.  **Caching:**
    
    *   `proxy_no_cache 1;`: Disables caching of the response.
        
    *   `proxy_cache_bypass 1;`: Ensures that caching is bypassed for every request.
        

In essence, this configuration sets up a proxy with specific headers, error handling, retry mechanisms, request size limits, and caching behaviour tailored to ensure that requests are efficiently handled and that any potential issues are retried within set limits.

Plugging in the configuration for a location server above into the previous file configuration that uses the include command to bring it into the global scope.

However, To complete this setup, we need to specify how we will be handling the request load, I mean which algorithm we will be using. The configuration below allowed us to specify just that using the **upstream directive**. This directive allows the use of group servers that can help use load balance requests. We also didn't have to specify the algorithm directly since Nginx allows us to use round-robin by default.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716466903600/d4387fb2-f152-42d7-859c-d927e1892a42.png align="center")

I don't think the client configuration is that important so I won't be touching up on that. To deploy this whole thing as an application, Docker was employed and it was quite simple to set up the container using the configuration below.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1716466964229/25b1c880-b757-4e5c-b54a-917ba825e3d6.png align="center")

And boom we are good to go 🚀🚀

Anyway, if you were wondering why the Christmas and New Year were built in the title that was because I wrote the application from the 25th to January 2nd 😅.

Looking back at our requirements, we achieved everything, and all servers and even our clients use this service before anything is fulfilled.

I hope you gained insight into nginx and its functionality and how it can help you handle large request loads to your servers.

Resources:

*   [https://docs.nginx.com/nginx](https://docs.nginx.com/nginx)
    
*   [https://en.wikipedia.org/wiki/Load\_balancing\_(computing)](https://en.wikipedia.org/wiki/Load_balancing_\(computing\))
    
*   [https://docs.docker.com/get-started/overview/](https://docs.docker.com/get-started/overview/)
    