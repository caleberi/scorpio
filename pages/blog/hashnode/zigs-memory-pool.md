---
title: "A Detailed Examination of Zig's Memory Pool"
summary: "Set up once, use multiple times."
authors:
  - "Caleb Adewole"
date: "2026-08-19"
topics:
  - "Zig"
  - "memory"
  - "Learning"
  - "Source Code"
type: "Blog"
image: "![image](../../../blobs/cover14.jpeg)"
highlight: purple
---
In a bid to understand how the memory pool works, I dug into the Zig memory pool source code. I plan to read the code for the allocator in the heap folder of the std library.

Let’s look at what it does and how it does—starting from the first error message definition.

## Out Of Memory Error

Error is not complicated in Zig. Obviously in this case, since we are dealing with memory there is a limit to how much memory the operating system can give out when resources are scarce. We define an error message like so:

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727881679178/65c9bfd1-e571-4eca-b02d-c1f44d1a5706.png align="center")

## The Memory Pool

Next, we define our memory pool as a generic constructor, from which we get back a type. The expectation is that we pass in a type in which we want the OS to create a pool of memory except in this place we need to understand the importance of memory alignment. An explanation of this can be found in Andrew Kelly’s [lecture](https://www.youtube.com/watch?v=IroPQ150F6c&t=1323s).

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727882208897/716b1c9f-9091-4498-a194-eb217e15fdee.png align="center")

Since there is a need to accommodate different alignments. For example, we have a struct like below:

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727884869694/ab19b6cf-31b9-4b7d-ac8c-996d6d87975d.png align="center")

This code snippet defines a struct `ll` with two fields: `width` of type `u8` (8-bit unsigned integer) and `height` of type `u9` (9-bit unsigned integer). It then prints the size of `u8`, the size of `u9`, and the alignment of the `ll` struct.

This program outputs:

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727885098226/730ed251-870a-4f77-88e9-1f283fa77da0.png align="center")

* `@sizeOf(u8) = 1`: This is straightforward. A `u8` is an 8-bit integer, which occupies exactly 1 byte.
    
* `@sizeOf(u9) = 2`: This is where things get interesting. Although `u9` only needs 9 bits, Zig allocates 2 bytes (16 bits) for it. This is because most hardware architectures are optimized for byte-aligned access, and the smallest unit larger than 9 bits that satisfies this is 2 bytes.
    
* `@alignOf(ll) = 2`: The alignment of a struct is determined by its largest field's alignment. In this case, it's the `u9` field, which has an alignment of 2 bytes.
    

What's fascinating about alignment, is the efficient use of what could have been wasted space.

To accommodate for growth and also specify alignment for the type we are constructing a memory pool for, zig allows programmers to specify options

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727885766995/bf7e4904-2913-4140-ab58-a9c4e74bbd63.png align="center")

since the memory pool increases in the amount of memory allocated, we can specify whether or not the memory pool is allowed to do that.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727885994126/3efa1763-883f-4581-8fca-9210ddba1987.png align="center")

Since the memory pool calls for the construction of an aligned pool for the stored data of the same type. Options can be passed in also.

> If you look closely , I asked why 29- bit alignment ? But, I haven’t figured out why yet .

Therefore by default, the memory pool supports 29-bit alignment.

### The Pool

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727887122262/86631b0a-79ac-42c6-87eb-e43e805c5825.png align="center")

Starting from the Pool constant which refers to the inner struct with the `@This()`

There is a maximal comparison between the item that should be stored in the loop and the node that will be abstracting the stored item which is the alignment of a `*anyopaque` which is synonymous with a `*void` .

Regarding node alignment, the memory pool keeps a free list of pointers to another pool, represented as a chain of aligned nodes. This alignment is based on the specified alignment or the alignment of the items we need to store in the pool. This is stored in the `item_alignment`.

However, there is a backing arena allocator that takes an existing allocator, wraps it, and provides an interface where one can allocate without freeing, and then free it all together. This allocator creates all our items for the pool. So the pool is initialized to bypass that backing memory allocator like so :

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727894471330/c8855cfa-21cc-443e-8f14-19f4a10fb658.png align="center")

As usual, for every allocation, there must be equal and opposite deallocation. Therefore the memory pool has a `deinit` method that performs that, cleaning up the backing allocator.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727896283520/8f4f81ca-1337-40ed-a463-022fdfdbf89d.png align="center")

## Creation & Destruction Of Memory Pool Items

To destroy is simple to create is hard lol. So let's destroy ...

To destroy an allocated item, the user of the memory pool only needs to specify the memory location of the item via a pointer and the pointer is set to undefined, thereby deallocating the memory and returning the pointer to the free list as a node pointer.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727896864511/85fd20e8-fe58-42b2-8aa7-8ce8a5a833e5.png align="center")

Up next, is the create functionality.

To create a new item in a memory pool, you call the create function and it will either fail or return an aligned pointer to the item requested but first it will create a node pointer for an item if a free list does not exist provided the pool is growable. If the free list of nodes exists, it will return the head of the free list and advance to the next node of the list essentially giving out the head of a linked list. If any issue occurs during allocation, an error is returned as shown below.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727898910657/1e728c10-3e27-4be7-b4ef-ff8a222a72e3.png align="center")

Looking closely at `pool.allocNew()` , it does only one simple thing. It calls the underlying allocator for a block of memory and aligns it to the item the pool stores. Think of it like it gave out blocks of cells for usage by the user.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727899542424/bad97f1a-d910-4717-8a50-6dbee377fe3d.png align="center")

## Resetting The Pool

Resetting the pool can be useful for clean up and it is done based on the reset mode configuration which determines how the underlying allocator will free all previously stored items in the pool. Depending on the setting, it can be done in batches without invalidating the actual pool.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727900315748/5286cc54-b9b5-4c33-b605-341646ec603c.png align="center")

## Pre-Heating The Memory Pool

Provide a size and you will get all the number of allocated items you want in a pool at once so when you call for an item it is available instead of the program requesting for allocation from the heap.

Although a while loop, the memory pool is bootstrapped for usage via a `create` call.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727902053980/5cfe0e85-b977-4644-8e13-b4c3d69b77bd.png align="center")

And that, lovely reader is how the whole memory pool works.

## Benefits of Memory Pools

Memory pools offer several advantages, such as improved performance and efficient memory management. Examples of such benefits are:

* **Improved Performance**: Memory pools significantly reduce the overhead associated with frequent allocations and deallocations.
    
* **Predictable Allocation Time**: Allocations from a memory pool typically have constant time complexity (O(1)), unlike system allocators which may have variable allocation times.
    
* **Simplified Memory Management**: Memory pools can simplify error handling and resource management. Instead of tracking and freeing individual allocations, entire pools can be deallocated at once, reducing the risk of memory leaks.
    
* **Bounded Memory Usage**: Memory pools can help in creating systems with bounded memory usage, which is crucial in embedded systems or other memory-constrained environments.
    

Anyway be sure to use the memory pool in the right place, especially in areas where there is the likelihood of a lot of reallocation.

A basic usage of the memory pool can be as simple as this test from the std library:

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1727902469763/900505c3-3c5a-4062-9e9c-6861a2808838.png align="center")

Anyway, that is all there is to the Memory pool.
