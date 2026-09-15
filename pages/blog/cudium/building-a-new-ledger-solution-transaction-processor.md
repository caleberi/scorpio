---
title: Building A New Ledger Solution - Transaction Processor
summary: Putting the pieces together in the processor to create a ledger.
authors: 
  - 'Adewole Caleb'
date: 2026-09-14
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
image: '![images](../../../blobs/cover49.webp)'
highlight: #FF5A00
---

> Part 3. Previous: [executor and transaction processor](/posts/blog/cudium/implementing-an-executor-for-transaction).

Starting from the [previous part](/posts/blog/cudium/implementing-an-executor-for-transaction), we have a transaction arriving as an event, control accounts ensured, and `ExecutorFactory` posting linked double-entry transfers atomically. Now we need to put the pieces together in a processor that actually drives all of that from a transaction record to a committed ledger entry.

Most of the components we need are already in place, so `TransactionProcessor` is mostly stitching them together. It provides a way to carry transaction state through the whole process, and it manages the tables involved along the way.

```js
function TransactionProcessor({ db, client, logger, accounts, executeLinked, transaction, transactionId, transactionType, ...ctx }) {
    const transactions = db.collection(databaseCollections.TRANSACTION);
    const ledgers = db.collection(databaseCollections.LEDGER);
    const auditingReconciler = AuditingReconciler(db, logger);
    const { planDeposit, planWithdrawal, planTransfer, planSwap, invertChain } = ChainPlanners();

    const state = { balances: {}, swapContext: null, clearingLedgerWritten: false };

    // stamp processed + before/after balances (and swap NGN total if present) onto the txn
    function buildProcessedUpdate() { /* ... */ }

    async function runChain(chain, meta, afterCommit) {
        const existing = await ledgers.findOne({ transactionId });
        if (existing) {
            // already posted: heal projections from the ledger, mark processed, skip a second apply
            await auditingReconciler.healBalance(existing, {});
            afterCommit?.(existing);
            await transactions.updateOne({ _id: transactionId, processed: { $ne: true } }, { $set: buildProcessedUpdate() });
            return existing;
        }

        const session = client.startSession();
        try {
            return await session.withTransaction(async () => {
                const result = await executeLinked({ chain, session, transaction, transactionId, ...meta });
                afterCommit?.(result);
                await transactions.updateOne({ _id: transactionId }, { $set: buildProcessedUpdate() }, { session });
                state.clearingLedgerWritten = true;
                return result;
            });
        } finally {
            await session.endSession();
        }
    }

    async function processTransaction() {
        switch (transactionType) {
            case SupportedTransactionTypes.DEPOSIT:
            case SupportedTransactionTypes.MIGRATION:
                // reject duplicate transactionReference; then planDeposit or planReverseDeposit
                return runChain(await planDeposit({ accounts, ...ctx }), { transactionType }, captureBalances);

            case SupportedTransactionTypes.WITHDRAWAL:
                return runChain(await planWithdrawal({ accounts, ...ctx }), { transactionType }, captureBalances);

            case SupportedTransactionTypes.TRANSFER:
                return runChain(await planTransfer({ accounts, ...ctx }), { transactionType }, captureBalances);

            case SupportedTransactionTypes.SWAP:
                // assert live swap rate/fee still match the txn, then planSwap (NGN → foreign)
                return runChain(await planSwap({ accounts, ...ctx }), { transactionType }, captureSwapBalances);

            case SupportedTransactionTypes.REVERSAL:
                // prefer invertChain(parent ledger transfers); otherwise re-plan the reverse of the parent type
                return runChain(invertChain(parentLedger.transfers), { transactionType: "REVERSAL" }, captureBalances);
        }
    }

    return { state, processTransaction, buildProcessedUpdate };
}
```

Let's break this down piece by piece.

## `RunChain`: The idempotent commit path

Every transaction type eventually funnels through `runChain`, and that's deliberate — it's the one place we guard against posting the same transaction twice.

The first thing `runChain` does is check whether a ledger entry already exists for this `transactionId`. Triggers can retry, workers can crash mid-flight and get replayed, and events can arrive more than once — so before doing any work, we ask the ledger itself whether this transaction has already been settled. If it has, we don't touch balances again. Instead, we call `auditingReconciler.healBalance` to make sure the wallet projection matches what the ledger already says, run the `afterCommit` callback so the caller still gets its balances, and stamp the transaction as processed if it somehow wasn't already. This turns `runChain` into a safe function to call more than once for the same transaction — which matters a lot in an event-driven system where "exactly once" is aspirational and "at least once" is what you actually get.

If no ledger entry exists yet, `runChain` opens a MongoDB session and runs the whole posting inside `session.withTransaction`. Everything that touches state — posting the chain through `executeLinked`, and stamping the transaction as processed via `buildProcessedUpdate` — happens under that same session. That's what makes the write atomic end to end: either the ledger entry, the wallet projections, and the `processed` flag on the transaction all land together, or none of them do. There's no window where the ledger has moved but the transaction still looks unprocessed, or vice versa.

`afterCommit` is a small but useful hook. It lets each transaction type capture whatever balances it cares about (`captureBalances` for the simple, single-currency cases; `captureSwapBalances` when a swap needs to remember both legs) without `runChain` itself needing to know anything about those differences.

## `BuildProcessedUpdate`: The shared closing move

Regardless of which transaction type ran, they all end the same way: the transaction document gets marked `processed`, along with a record of the balances before and after (and, for a swap, the NGN-equivalent total moved). Centralizing that in `buildProcessedUpdate` means every transaction type writes the same shape of "this is done" update, which keeps downstream consumers — reporting, statements, support tooling — from having to special-case how each transaction type reports its own completion.

## `ProcessTransaction`: One switch, five behaviors

With `runChain` and `buildProcessedUpdate` handling the shared plumbing, `processTransaction` itself stays deliberately thin. It's a switch on `transactionType`, and each branch does exactly two things: plan a chain, and hand it to `runChain` with whatever balance-capture callback fits that transaction type.

- **Deposit and migration** share a branch because a migrated transaction is, at the ledger level, just a deposit with a different origin. Before planning the chain, we reject a duplicate `transactionReference` so the same external deposit can't be credited twice — then `planDeposit` builds the chain we walked through in [Part 2](/posts/blog/cudium/implementing-an-executor-for-transaction).
- **Withdrawal** and **transfer** follow the same shape: plan the chain for that type, run it, capture the resulting balances.
- **Swap** does one extra check before planning: it asserts that the rate and fee baked into the transaction still match the live rate at execution time, since a swap that sat in a queue for even a few seconds can no longer be posted at a stale rate. `planSwap` then builds the NGN-to-foreign-currency chain, and `captureSwapBalances` records both sides of the trade rather than a single balance.
- **Reversal** is the odd one out, in a good way: instead of planning a fresh chain, it prefers to invert the *actual* transfers that were posted for the parent transaction (`invertChain(parentLedger.transfers)`). Reversing what was really posted — rather than re-deriving what should have been posted — means a reversal can't drift from its parent even if the planning logic for that transaction type changes later. Only when the parent ledger isn't available do we fall back to re-planning the reverse of the parent type from scratch.

## Tying it back together

Across these three parts, the pipeline now runs end to end: a transaction lands as a database event, `FundChecker` and the control-account setup from [Part 1](/posts/blog/cudium/building-a-new-ledger-solution) get us to the door, `ExecutorFactory` and `executeLinked` from [Part 2](/posts/blog/cudium/implementing-an-executor-for-transaction) post a balanced, hash-linked chain atomically, and `TransactionProcessor` is the layer that decides which chain to plan and guarantees it only ever gets posted once. Nothing here is exotic on its own — double-entry legs, optimistic concurrency, idempotent writes — but wiring them together this way is what lets the ledger stay correct under retries, concurrent triggers, and the occasional stale swap rate, without needing a human to intervene.