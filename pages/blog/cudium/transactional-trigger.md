---
title: 'Event-driven wallet system all piggybacked on top MongoDB atlas service trigger support.'
summary: 'Running transaction processing and wallet management system all piggybacked on top MongoDB atlas service trigger support for Cudium.'
authors:
  - 'Adewole Caleb'
date: '2026-08-19'
topics:
  - 'Cudium'
  - 'Engineering'
  - 'MongoDB'
  - 'Triggers'
  - 'Transactions'
  - 'Wallets'
  - 'Javascript'
  - 'Database'
type: 'Blog'
image: '![image](../../../blobs/cover10.png)'
---


> Event-driven wallet system all piggybacked on top MongoDB atlas service trigger support.
> 
> You will learn how triggers in MongoDB work, transaction  
> handling in MongoDB and little bit of JS
> 
> PS - the title was not easy to choose since it manages wallets and transactions

So I am a big fan of designing systems, comparing tradeoffs and implementing systems to see if they work and reduce operation and development costs while still providing value to users.  
A while back, during my final exam in college, I was tasked with developing a payment system for the startup I work for. Coming from a company with all the financial resources to run queues, redis clusters e.t.c to a smaller company, We had to pivot.

> Disclaimer: My CTO signed off on this article if you were wondering 😂

By pivoting I mean since we typically handle all transactions via third-party providers and the time to market with a new payment system coupled with the legalities involved was not worth it. We decided that we should stick with the third-party approach but manage all the transactions in-house with a wallet system which we didn't have at the time and offload the transaction to the third party which is essentially the banking system

> Goals: Keeping it simple and horizontally scalable

By default, one could go with several options to create this system such as

1.  Setup a Queue-based system that updates database information e.g Kafka
    
2.  Use Event Triggers
    

One thing about choosing how to design this system is to consider setup and development costs. Since it is a significant setup and development cost to set up a queue system from scratch, we discovered that MongoDB allows us to use something adaptable to our current system. Funny, I forgot to talk about our system.

We work with Sails JS for every backend-related system designed internally and actively use MongoDB as our database engine. The belief is that you can scale horizontally without so much stress with the right system. In summary, we chose event triggers, specifically, Mongo database triggers. What are triggers?

### What are Triggers?

According to MongoDB resource documentation, Database triggers can be used to implement complex data interactions. A trigger can update information when related data changes (i.e. when a user profile picture is replaced, triggering an update of the user activity information), or interact with a service when new data is inserted (i.e. when a new calendar entry is added, triggering an email notification).

**Main Purposes of Database Triggers**

Database triggers serve several important functions:

1.  **Audit:** Triggers can track changes made to records. For instance, a compliance team might need to know who updated a record. A trigger can automatically record the user who made the change in a "Last Updated By" field.
    
2.  **Data Consistency:** Triggers help maintain consistent data formats. For example, to ensure all city names in a database are in uppercase, a trigger can automatically convert any input to uppercase, regardless of how it was entered.
    
3.  **Data Integrity:** Triggers enforce rules to ensure valid data combinations. For instance, they can verify that an order's start date is before its end date, preventing invalid date entries before the transaction is finalized.
    
4.  **Data Events:** Triggers can initiate actions based on specific events. For example, they can generate a report after data is added or notify users when a certain condition is met, like enough participants joining a game.
    

### MongoDB Triggers

MongoDB Atlas supports database triggers that let the user program the function that will be executed when the database event is fired, take care of server management and provide a handy user interface (which means less code to write).

Types of database triggers supported by MongoDB:

1.  Database Triggers: Perform some action when a document is updated, added, or removed.
    
2.  Scheduled Triggers: Scheduled actions occur at a specific time or set interval. MongoDB Atlas leverages an intuitive approach to scheduling triggers using the CRON expression language.
    
3.  Authentication Triggers: Actions happen when creating or deleting a user or logging into MongoDB. This is only supported in the MongoDB realm.
    

![Image description](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/4sgil0af1kzvvywffn8o.png align="left")

### Structure of a Database Trigger On MongoDB

MongoDB Atlas Trigger executes application and database triggers since they are reactive to events or user-defined schedules. Listening to the events of a specific supported and configured type, A trigger is a basic atlas function defined with the signature below when a trigger observes an event that matches your specified configuration **fires**. The trigger then passes an object representation of the event to the trigger to work with.

```javascript
exports = async function(changeEvent) {
    // business logic for processing documents based on configuration
}
```

MongoDB App service provides a way to keep track of the latest execution time for each trigger and guarantees that each event is processed at least once. However, the limitations imposed by the trigger's capacity are determined by its event ordering configuration, which is based on:

*   Ordered triggers process events from the change stream one at a time in sequence. The next event begins processing only after the previous event finishes processing.
    
*   Unordered triggers can process multiple events concurrently, up to 10,000 at once by default. If your Trigger data source is an M10+ Atlas cluster, you can configure individual unordered triggers to exceed the 10,000 concurrent event threshold
    

Trigger capacity doesn't directly measure throughput or guarantee a specific execution rate. It sets the maximum number of events a Trigger can handle at once. The actual processing rate depends on the Trigger function's runtime logic and the number of events it receives over time. To improve the throughput, One can opt for the following :

1.  Trigger runtime logic optimization
    
2.  Reduction of event object size with trigger projection filter
    
3.  Use the right match filter condition to reduce the number of events the trigger processes.
    

> One thing to note is that there is a limitation on the total number of database triggers based on the subscribed cluster size.

Now that we have seen the MongoDB atlas trigger structure, let's take a superficial look at how the wallet system was implemented. Please note that I won't be showing the code just some key functions that help process the event information passed to the database before a commit is made ( company's policy)

### The Wallet System

To support any third payment provider, we need our own in-house wallet management system as previous integration showed that not all third-party providers support API that allows users to manage wallet and transaction with lower latency ( milliseconds).

Initially, all our databases were set not to rely on events, so after some engineering debate and R&D., I designed a transaction processing system and a wallet management system.

By setting up a trigger to monitor Transactional event document actions such as creation and deletion, we discovered that handling all necessary resolutions for all supported transactions was possible. The main objective was to differentiate between debit and credit operations. Fortunately, MongoDB facilitates [ACID](https://en.wikipedia.org/wiki/ACID) operations through sessions, as an alternative to conventional SQL transactions.

To better understand these, let's take a quick look at the `credit` function

![Image description](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/8x6tf2nq9ezg5yypqnha.png align="left")

To have a proper acidic credit logic we had to use session to guarantee the atomic attribute of crediting a user.

I'll also demonstrate a debit function now. By the way, most of the processing is managed through functions, in case you were curious.

![Image description](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/ovbbowfx4jnbgk983wiy.png align="left")

Both the `credit` and `debit` functions help in adding and removing funds from involved parties and are wrapped around a transaction section which helps enforce the ACID operation.

![Image description](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/j38ycelw9h5obpgii4ld.png align="left")

In the code above, it's important to highlight the transaction option, which informs the database on how to maintain consistency [(Transaction API)](https://www.mongodb.com/docs/manual/core/transactions/). If an error occurs then the entire commit will be reverted.

Now back to how to trigger functions, We need to extract some information from the parsed change event information from MongoDB. Essentially, a change event is the necessary data pushed from the data to the database but since it is passed via a change stream to the MongoDB database. This change event data is passed into the trigger function based on the configuration.

![Image description](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/nwi6z8k7s2p3kj6n3w88.png align="left")

So every time, the change event matches the set configuration that causes the trigger run.

The outcome of this discussion can be applied to different use cases, such as sending an email when a user registers. In our case, we had to implement it to process payment and manage our user's wallets.

The benefits we gained are the following :

1.  We were able to perform about $65million in volume
    
2.  Processed ~ $650K in a day ( My CTO showed me cause I didn't believe it initially ) with a capacity supporting ~=50K transactions.
    
3.  Started building a dashboard on the platform.
    
4.  Seamless integration
    
5.  Scalability and offloading to MongoDB atlas service
    
6.  Minimal to no expense as we operate on free trigger instances.
    

However, one disadvantage of this solution is all about Vendor locking. Anyway, it is all about risk versus reward.

I hope you gained insight into transactions in MongoDB and how operations can be offloaded to the database layer which can help improve your throughput.

Resources:  
\- [https://www.mongodb.com/docs/manual/core/transactions](https://www.mongodb.com/docs/manual/core/transactions/)  
\- [https://www.mongodb.com/docs/atlas/app-services/triggers](https://www.mongodb.com/docs/atlas/app-services/triggers/)  
\- [https://www.mongodb.com/resources/products/capabilities/database-triggers](https://www.mongodb.com/resources/products/capabilities/database-triggers)  
\-
