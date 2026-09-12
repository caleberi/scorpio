---
title: 'Building a New Ledger Solution: Transaction as an Event'
author: 'Adewole Caleb'
date: 2026-09-12
tags:
  - 'Engineering'
  - 'Infrastructure'
  - 'Ledger'
  - 'Event-Driven Architecture'
  - 'Transaction'
  - 'Javascript'
  - 'Accounting'
  - 'Double-Entry Bookkeeping'
type: 'Blog'
image: '![images](../../../blobs/cover24.webp)
highlight: green
---

I am writing this piece staring at my recent work on the version two implementation of the ledger solution for Cudium, which I worked on with my team lead about 2-3 years back. I have been meaning to write about this for a while now, but I have been busy with other projects and personal stuff. It is not yet deployed to production — it is a work in progress, and I am sharing my thoughts and learnings with you.

## The problem

We are growing, and it is becoming increasingly difficult to monitor and track the flow of money in and out of the company. The initial solution simply logged all transactions and reported them from the database. If, for example, you wanted to know the balance of a particular account, you looked into the wallet and saw the balance. This is not scalable and not efficient. A question like "how much money did we make per currency?" becomes difficult to answer.

Funny enough, I have always loved Zig, and then I started following TigerBeetle and was blown away by the simplicity and elegance of the design. I have always wanted to build a ledger solution like that, but I never had the opportunity to. So I decided to build one for Cudium — not in Zig, and not using TigerBeetle itself, but using event-driven architecture to build a solution that is scalable and efficient, borrowing a bit from TigerBeetle's approach so that we could solve our problem while keeping costs down, since we are not yet a big company and are not moving a lot of money.

After reading a couple of articles from renowned payment companies like Stripe and Airbnb, I realized that they use event-driven architecture to build their ledger solutions to some extent. So I decided to use the same approach, but also bring in ideas from TigerBeetle's approach as a financial ledger database to solve the problem we face.

## The solution: Transaction as an event

> What happens when a transaction is created and treated as an event?

Transaction as an event is one of the most common ways of building financial solutions, because if every movement of assets from point A to point B is treated as an event, then a transaction is just an event wrapped around the movement of assets. Obviously, money is not the only asset that gets moved — other assets like inventory or services can move too.

> There are many things in this world that have value which can be exchanged, which is why I like to define a transaction, financially, as a movement of assets and liabilities.

Back to the processor: if a transaction is considered an event, what are the key things we need to keep in mind when working with such an event, to be able to call it a successful or failed transaction and still have balanced books?

## Key ingredients to consider when building a ledger solution for transactions

- **Trust**

When building a ledger solution for transactions, one needs to be able to evaluate the trustworthiness of the transaction and the integrity of the data, since we treat the data as a source of truth. Keeping this in mind while building ensures we can be rest assured of the whole system.

- **Consistency**

All transactions that enter the system must be processed with constant behaviour, meaning the transaction must be deterministic and lead to the same outcome — i.e., idempotent. Once a transaction is processed, reprocessing it has no further effect on the system.

- **Speed of execution**

No one loves a slow transaction. An average person expects their assets to be processed at a very fast speed, although this is subject to the provider's ability to live up to that promise. I personally expect any system I build to operate in milliseconds, not seconds.

- **Atomicity**

Any transaction processed must be atomic, meaning it must either fully succeed or fully fail — never partially. This ensures the transaction never leaves the system in a state that's inconsistent with the rest of it.

- **Isolation**

Transactions must be isolated from each other, meaning one transaction's processing must not be affected by another's.

- **Correctness**

At the end of the day, we need to be able to ensure the transaction is correct and the data is accurate and consistent. This is how we build a trustworthy system.