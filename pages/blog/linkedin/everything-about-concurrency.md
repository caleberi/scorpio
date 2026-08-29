---
title: 'Review: What Every Systems Programmer Should Know About Concurrency by Matt Kline'
summary: 'Review of the book "What Every Systems Programmer Should Know About Concurrency" by Matt Kline'
authors:
  - 'Adewole Caleb'
date: '2026-08-15'
topics:
  - 'Concurrency'
  - 'Systems Programming'
  - 'Engineering'
  - 'Review'
  - 'Paper'
type: 'Blog'
image: '![image](../../../blobs/cover31.webp)'
---

> Concurrency is perilious art.

Modern computing has transitioned from single-core to multi-core architectures, fundamentally changing how instruction streams are processed. Multi-core systems enable parallel execution through sophisticated mechanisms like threads, processes, and interrupt service routines—abstractions designed to facilitate shared state management.

## Instruction Processing and Memory Coherence
The contemporary CPU architecture is complex, featuring multiple data paths for different instruction types and an intelligent scheduler that dynamically routes and reorders instructions. Each processor core contains a store buffer that manages pending write operations while continuing to execute subsequent instructions. This approach maintains memory coherence, ensuring that writes performed on one core are eventually observable across all cores—a technically challenging synchronization problem.

## Synchronization Approaches
To address memory synchronization challenges, the paper explores several critical strategies:

- **Implementation Techniques:** Synchronization tools are integrated through assembly or compiler extensions and Library-provided synchronization mechanisms. This ensures consistent execution order matching the program's specified sequence

- **Atomic Operations:** The paper emphasizes atomicity, with a key principle being that thread synchronization variables should not exceed the CPU's word size to prevent "torn" read and write operations.

## Concurrency Mechanisms
The paper detailed four primary atomic operation types and how they relate to concurrency:

- **Read-Modify-Write (RMW):** Atomically loading, modifying, and storing a value in a single operation

- **Exchange:** Replacing an existing value with a new value

- **Compare and Swap:** Conditionally exchanging a value based on matching predefined expectations

- **Fetch:** Atomically reading a value, performing an operation, and returning the original value

Another key discussion in the paper was the split between Atomic load, store and RMW operation into blocked and lockless concurrency. Blocking synchronisation methods are usually simpler and easier to think about since they can pause thread execution for an arbitrary amount of time e.g.  with  mutexes.  However, they can lead to deadlocks or livelocks. On the other hand, Lockless synchronization ensures that there is  progress at time instances with no blocking of thread  e.g. parallel processing of audio sound.

Lockless algorithm does not improve speed or is better than blocking algorithm - they are just to solve different purposes.

## Conclusion
The paper provides a nuanced exploration of the intricate interactions between hardware architecture and software synchronization strategies, highlighting the sophisticated mechanisms underlying modern concurrent computing systems.



Do, take time to read the [paper](https://assets.bitbashing.io/papers/concurrency-primer.pdf).







