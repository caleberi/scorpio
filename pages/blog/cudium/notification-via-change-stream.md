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


### Subscription is how users opt in to receive notifications

One important thing to note is that notification rules are not the same as notification subscriptions. Notification rules are the rules that are used to determine when a notification should be sent. Notification subscriptions are the subscriptions that are used to determine which notifications should be sent to which users.

Schema representation of notification subscription we look like this:

```json
{
  "_id":  "6afe96a16164ec60502922b5",
  "rule": "6afe96a16164ec60502922b5",
  "user": "6aeba6d060aba9b84be9cfcf",
  "enabled": true,
  "createdAt": "2026-11-19T06:26:41.584Z",
  "updatedAt": "2026-11-19T06:47:30.563Z"
}
```
Essentially, a subscription is a relationship between a user and a notification rule. It is used to determine which notifications should be sent to which users.

### How do we know when a notification should be sent?

To know when a notification will be sent we need to register enabled notification for monitoring against the database. For that we need to setup background worker system that registers consumers that tracks various intention for notification. To do this, it will be lovely to pick well tested and reliable library that can help us with this. Bull MQ is a good choice for this.

Let's setup a quick representative version of how it will look like

```javascript
const fs = require('fs');
const path = require('path');
const { createNodeRedisClient } = require('bullmq');
const { createClient } = require('redis');
const Sails = require('sails').constructor;
const { startBullmqWorker } = require('./transports/bullmq');
const { watchSources } = require('./change-streams/watch-sources');
const { createWorkerLogger } = require('./logger');

function isFunction(func) {
  return typeof func === 'function';
}

function loadConsumers() {
  const dir = path.join(__dirname, 'consumers');
  return fs.readdirSync(dir)
    .filter((file) => /^.+-consumer\.js$/.test(file))
    .map((file) => require(path.join(dir, file)))
    .filter((mod) => mod && isFunction(mod.workerFunction));
}

function resolveRoles(consumer) {
  const launch = sails.config.custom.constants.workerLaunchAs;
  const raw = isFunction(consumer.getLaunchAs) ? consumer.getLaunchAs() : consumer.launchAs;
  const repeat = isFunction(consumer.getRepeat) ? consumer.getRepeat() : consumer.repeat;
  const hasRepeat = Boolean(repeat && (repeat.pattern || repeat.every));
  const chosen = raw || (hasRepeat ? launch.BOTH : launch.WORKER);
  if (chosen === launch.BOTH) {
    return [launch.WORKER, launch.CRON];
  }
  return [chosen];
}

const sailsApp = new Sails();

sailsApp.load({
  log: { level: 'warn' },
  models: { migrate: 'safe' },
  hooks: { sockets: false, pubsub: false, grunt: false }
}, async (err) => {
  if (err) {
    console.error('Error loading Sails app:', err);
    process.exit(1);
  }
  const logger = createWorkerLogger('notifications', 'workers');
  const url = sails.config.custom.queueRedis && sails.config.custom.queueRedis.url;
  if (!url) {
    logger.error('worker.noRedis');
    process.exit(1);
  }
  const redisClient = createClient({ url: url });
  redisClient.on('error', () => null);
  const opened = await redisClient.connect().catch(() => null);
  if (!opened) {
    logger.error('worker.redisFailed');
    process.exit(1);
  }
  const connection = createNodeRedisClient(redisClient);
  const env = sails.config.environment || 'development';
  const running = [];
  const consumers = loadConsumers().filter((consumer) => consumer.enabled !== false);
  for (let index = 0; index < consumers.length; index++) {
    const consumer = consumers[index];
    const queueKey = isFunction(consumer.getQueueKey) ? consumer.getQueueKey() : consumer.queueKey;
    const roles = resolveRoles(consumer);
    for (let roleIndex = 0; roleIndex < roles.length; roleIndex++) {
      const started = await startBullmqWorker({
        consumer: consumer,
        queueKey: queueKey,
        env: env,
        connection: connection,
        role: roles[roleIndex]
      });
      if (started) {
        running.push(started);
      }
    }
  }
  const watcher = await watchSources(logger).catch(() => null);

  const shutdown = async () => {
    if (watcher && watcher.stop) {
      await watcher.stop().catch(() => null);
    }
    await Promise.all(running.map((entry) => entry.stop())).catch(() => null);
    await redisClient.quit().catch(() => null);
    process.exit(0);
  };
  process.on('SIGINT', () => { shutdown(); });
  process.on('SIGTERM', () => { shutdown(); });
  logger.info('worker.ready', { count: running.length });
});
```

This code sample above just loads up consumer as background worker system. There are always specific to what they ought to do.

Obviously, the workers need to consume messages from the queue and process them. And we don't have one setup yet so let's create a queue.

```javascript
const { Worker, Queue } = require('bullmq');
const { createWorkerLogger } = require('../logger');

function isFunction(func) {
  return typeof func === 'function';
}

function getConsumerRepeat(consumer) {
  return isFunction(consumer.getRepeat) ? consumer.getRepeat() : consumer.repeat;
}

async function startBullmqWorker({ consumer, queueKey, env, connection, role }) {
  const transports = sails.config.custom.constants.workerTransports;
  const launch = sails.config.custom.constants.workerLaunchAs;
  const namespace = env + '-' + queueKey;
  const instanceName = consumer.name + ':' + role;
  const logger = createWorkerLogger(instanceName, namespace);

  if (role === launch.CRON) {
    return startCronScheduler({ consumer, namespace, connection, logger, queueKey, instanceName });
  }
  if (role !== launch.WORKER) {
    logger.error('worker.skipped', { reason: 'unknown-role', role: role });
    return null;
  }

  const worker = new Worker(namespace, (job) => {
    return consumer.workerFunction({ job: job, namespace: namespace, logger: logger });
  }, Object.assign({ connection: connection }, consumer.options || {}));

  worker.on('completed', (job) => {
    const waitMs = Number(job.processedOn) - Number(job.timestamp);
    const runMs = Number(job.finishedOn) - Number(job.processedOn);
    sails.helpers.notifications.recordJobSample.with({
      jobName: job.name,
      waitMs: waitMs,
      runMs: runMs
    }).catch(() => null);
    logger.info('lifecycle.completed', { jobId: job.id });
  });
  
  worker.on('failed', (job, err) => {
    logger.error('lifecycle.failed', { jobId: job && job.id, err: err && err.message });
  });
  worker.on('error', (err) => {
    logger.error('lifecycle.error', { err: err && err.message });
  });

  logger.info('worker.start', { transport: transports.BULLMQ, role: launch.WORKER, queueKey: queueKey });
  return {
    name: instanceName,
    stop: async () => {
      await worker.close();
    }
  };
}

async function startCronScheduler({ consumer, namespace, connection, logger, queueKey, instanceName }) {
  const repeat = getConsumerRepeat(consumer);
  if (!repeat || !(repeat.pattern || repeat.every)) {
    logger.warn('scheduler.skipped', { reason: 'missing-repeat' });
    return null;
  }
  const queue = new Queue(namespace, { connection: connection });
  const scheduler = {};
  if (repeat.pattern) {
    scheduler.pattern = repeat.pattern;
  }
  if (repeat.every) {
    scheduler.every = repeat.every;
  }
  await queue.upsertJobScheduler(consumer.name, scheduler, {
    name: consumer.jobName || consumer.name,
    data: consumer.jobData || {}
  }).catch((err) => {
    logger.error('scheduler.failed', { err: err.message });
  });
  logger.info('scheduler.start', { queueKey: queueKey, every: scheduler.every, pattern: scheduler.pattern });
  return {
    name: instanceName,
    stop: async () => {
      await queue.close();
    }
  };
}

module.exports = { startBullmqWorker };
```
