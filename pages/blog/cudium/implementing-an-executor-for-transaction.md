---
title: 'Building a New Ledger Solution: Executor and Transaction Processor'
summary: 'How ExecutorFactory posts linked double-entry transfers atomically, and how TransactionProcessor routes each transaction type through that path.'
authors:
  - 'Adewole Caleb'
date: 2026-09-13
topics:
  - 'Engineering'
  - 'Infrastructure'
  - 'Ledger'
  - 'Event-Driven Architecture'
  - 'Transaction'
  - 'Javascript'
  - 'Accounting'
  - 'Double-Entry Bookkeeping'
type: 'Blog'
image: '![images](../../../blobs/cover27.webp)'
highlight: amber
---

> Part 2. Previous: [transaction as an event](/posts/blog/cudium/building-a-new-ledger-solution).

I am continuing from the [first part](/posts/blog/cudium/building-a-new-ledger-solution), where a transaction arrives as a database event, control accounts are ensured, and FundChecker decides whether the customer wallet can cover the movement.

Accounts and the fund check get us to the door. This part is the write: `ExecutorFactory` posts linked ledger transfers in one go, and `TransactionProcessor` decides which legs to post for a deposit, withdrawal, transfer, or swap.
