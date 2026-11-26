---
title: 'Notification via Change Stream for Dashboard Updates'
summary: 'What approach and tradeoff did we take for notification via change 
mongodb stream for dashboard updates.'
authors:
  - 'Adewole Caleb'
date: '2026-11-25'
topics:
  - 'Cudium'
  - 'Engineering'
  - 'Change Stream'
  - 'MongoDb'
  - 'Dashboard'
  - 'Sails Js'
  - 'Email'
  - 'Socket.io'
  - 'Slack'
  - 'Web Push Notifications'
image: '![image](../../../blobs/cover61.webp)'
---

## The dashboard without notification 

A while back, we built a dashboard for stakeholders and support team to help with onboarding new businesses , tracking transactions, handling broadcast messages, viewing transaction metrics and other relevant information.

In the midst of this build, there was a missing piece. One may wonder what that is. The answer is simple. We forgot to attend to the problem faced by stakeholders and support team when they need to be notified about changes in the business, transaction, or any type of event happening  in other moving system that we run.

> There was once a bell, grand to behold, that never rang.
> This is the tale of a board without a voice,
> a dashboard full of signals, and no sound.

A poem about the dashboard. So what was the solution? Sure to add a notification support but how and what reason should use to support that.

### Designing a solution for the bell to ring 

Let's start by understanding the context of the problem. The dashboard is a web application that runs on the browser and it fetches data from different serving sources via an internally running forward proxy with sails Js ( check out [architecting a sails proxy](/blog/cudium/architecting-a-sails-proxy) ) for more explanation on that can be done. Also database which is a mongodb behind the scene is the source of truth for the data. 

This generates some questions like the following:

- How do we know when something happens in the servers running individually? Internally within the server and also externally in the database.

- As super admin, tracking a specific action via the dashboard can change at interval. Should we deal with dynamically configurable notification settings or just create some set of notification settings that supported by default?

- While the configuration might be dynamic, can we still support subscription per stakeholder's interest?

- What advantage does the database provide us really so we can easily what is going on right as that level?

All this question comes handy during the design phase of the solution. Reading about triggers and change stream was a good start.

Let's answer the question one by one so that we can have a clear picture of the solution.

**How do we know when something happens in the servers running individually? Internally within the server and also externally in the database.**

We can either allow the server to post event over http or websocket. Obviously, websocket is a better choice since it keeps the connection open and the server can push event to the client without the client having to request for it. In this case, we won't be using websocket because we need to avoid open connection to the dashboard connection via other services. A simple http *POST* request to the dashboard can be used to send event to the dashboard.

Making it possible for the application to inform the dashboard about the event that happens in the server . Something rather outboxed to server.

External to the server, we can use change stream to listen to the database for changes. This is a good way to know when something happens in the database.


**As super admin, tracking a specific action via the dashboard can change at interval. Should we deal with dynamically configurable notification settings or just create some set of notification settings that supported by default?**

With an assumption that there exist a super admin in charge of assigning roles to the users (A existing feature in the dashboard). 
We can make an assumption that the super admin can configure some set of notification settings that will be used to notify the users about the event that happens in the server or database. This is actually better because it allows us to avoid having to update the notification manually via bootstrap script but rather having an interactive user interface to configure the notification settings.

**What advantage does the database provide us really so we can easily know what is going on right as that level?**

With the introduction of triggers and change stream, we can easily know event happening right with the database. Tracking operation that database got right from application interacting with it. From update,delete,insert, etc. operation are available to us.


With the above questions answered to some extent,  we can now start with desiging  a solution.

### Rules are the starting point

Starting with notification rules is perhaps the best way to go about it since rules creation helps us in focusing more on the property that can help us solve the problem. One interesting thing about drafting out a schema is that we can identify who gets the message, who sends the message ,what the message is about and many more.

Let's draft out a schema for the notification rules.
```json
{
  "_id":  "6afe96a16164ec60502922b5",
  "event": "business.declined",
  "conditions": {
    "$and": [
      {
        "fields": [{ "status": "declined"}],
        "model": "Business",
        "source": ["business"]
      }
    ]
  },
  "audience": {"roles": ["ADMIN","SUPER_ADMIN"]},
  "requiredPermission": [{ "key": "admin_business_profile", "action": "READ" }],
  "mode": "opt_in",
  "allowedChannels": ["in_app","email"],
  "defaultChannels": ["in_app"],
  "excludeActor": true,
  "enabled": false,
  "deletedAt": "2026-11-19T06:47:30.563Z",
  "version": 11,
  "createdBy": "6aeba6d060aba9b84be9cfcf",
  "createdAt": "2026-11-19T06:26:41.584Z",
  "updatedAt": "2026-11-19T06:47:30.563Z"
}
```

The above schema is a simple one that can be used to notify the users about the event that happens in the server or database.

- `_id`: The unique identifier for the notification rule.
- `event`: The event that triggers the notification.
- `conditions`: The conditions that must be met for the notification to be sent.
- `audience`: The audience that receives the notification.
- `requiredPermission`: The permission that is required for the user to receive the notification.
- `mode`: The mode of the notification.
- `allowedChannels`: The channels that are allowed for the notification.
- `defaultChannels`: The default channels for the notification.
- `excludeActor`: Whether to exclude the actor from the notification.

> In my opinion, the important part of this schema is ignoring noise and focusing on simplicity about what is needed  at the moment and this schema answers it.

With this schema, all we need to do is to support **GET**, **POST**, **PUT**, **DELETE** operations for the notification rules. It is also important to ensure that pagination is supported when fetching the notification rules.

One important thing to note is that notification rules are not the same as notification subscriptions. Notification rules are the rules that are used to determine when a notification should be sent. Notification subscriptions are the subscriptions that are used to determine which notifications should be sent to which users.


