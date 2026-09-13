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
image: '![images](../../../blobs/cover28.webp)'
highlight: amber
---

> Part 2. Previous: [transaction as an event](/posts/blog/cudium/building-a-new-ledger-solution).

I am continuing from the [first part](/posts/blog/cudium/building-a-new-ledger-solution), where a transaction arrives as a database event, control accounts are ensured, and FundChecker decides whether the customer wallet can cover the movement.

Accounts and the fund check get us to the door. This part is the write: `ExecutorFactory` posts linked ledger transfers in one go, and `TransactionProcessor` decides which legs to post for a deposit, withdrawal, transfer, or swap.

## ExecutorFactory

A typical execution engine is singleton that provides all neccessary component to process transactions. It is responsible for balance reconcilation for accounts in question, transaction assertion, settlement checks and posting of transaction legs. 

First, let see how we get the balance of an account using effective running sum calculation via checkpoint id (basically a snapshot of the account balance at a point in time) to avoid some amount of computational overhead.

```js
async function deriveBalance(db, account, session) {
    const wallet = await db.collection(databaseCollections.WALLET)
        .findOne(walletFilterForRef(account), { session });
    // missing wallet is a hard fail — the registry should have created it

    // effects after the last checkpoint (snapshot), not a full ledger scan
    const effects = await sumClearingEffects(db, account, session, {
        checkpointId: wallet.effectsCheckpointId,
    });

    // frozen opening if we have one; otherwise back-solve from availableBalance
    const opening = isDefined(wallet.ledgerOpeningBalance)
        ? Number(wallet.ledgerOpeningBalance)
        : toMinorUnits(wallet.availableBalance) - effects;

    return { wallet, openingBalance: opening, effectsBalance: effects, derivedBalance: opening + effects };
}
```

To make wallet balance calculation easier, we need to create a simple apply function that will help in calculating balance information for an account while checking the posting type in question to decide such calculation.

```js
function WalletPorterFactory(db, { logger, fundCheck }) {
    async function applySide(account, side, amount, { session, running }) {
        const key = walletKey(account);
        const units = toMinorUnits(amount);
        const nature = account.nature || natureOf(account.role);

        // first touch: seed this account's running balance from deriveBalance
        if (!running[key]) {
            const derived = await deriveBalance(db, account, session);
            running[key] = { account, balanceUnits: derived.derivedBalance };
        }

        // customer debit: FundChecker must pass, and the wallet cannot go negative
        if (isCustomer(account.role) && side === AccountingPostingSide.DEBIT && fundCheck) {
            const { hasSufficientFund } = await fundCheck(account.businessId, amount, account.currency, session);
            if (!hasSufficientFund) throw new Error("insufficient funds");
        }

        // same sign rule as transferEndpointEffect: asset debit-up, liability debit-down
        const debitUp = debitIncreasesBalance(nature);
        const delta = side === AccountingPostingSide.DEBIT
            ? (debitUp ? units : -units)
            : (debitUp ? -units : units);

        const before = running[key].balanceUnits;
        const after = before + delta;
        if (isCustomer(account.role) && after < 0) throw new Error("insufficient funds");
        running[key].balanceUnits = after;

        return { balanceBefore: fromMinorUnits(before), balanceAfter: fromMinorUnits(after), ...account };
    }

    return { applySide };
}
```