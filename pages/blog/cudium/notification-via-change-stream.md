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

## The dashboard without notifications

A while back, we built a dashboard for stakeholders and the support team to help with onboarding new businesses, tracking transactions, handling broadcast messages, viewing transaction metrics, and more.

Midway through the build, we realised a piece was missing. One may wonder what that is. The answer is simple: we forgot to address how stakeholders and the support team get notified about changes in a business, a transaction, or any other event happening in the other moving systems we run.

> There was once a bell, grand to behold, that never rang.
> This is the tale of a board without a voice,
> a dashboard full of signals, and no sound.

That is a poem about the dashboard. So what was the solution? Adding notification support, sure, but how, and on what basis should it work?

### Designing a solution for the bell to ring

Let's start by understanding the context of the problem. The dashboard is a web application that runs in the browser and fetches data from different sources through an internal forward proxy built with Sails.js (check out [architecting a sails proxy](/blog/cudium/architecting-a-sails-proxy) for more on how that works). Behind the scenes, a MongoDB database is the source of truth for the data.

This raises some questions:

- How do we know when something happens in the servers running individually? Both internally within a server and externally in the database.

- As a super admin, the specific actions worth tracking can change over time. Should we support dynamically configurable notification settings, or just create a set of notification settings supported by default?

- While the configuration might be dynamic, can we still support subscriptions based on each stakeholder's interest?

- What advantage does the database really give us, so we can easily see what is going on right at that level?

These questions came in handy during the design phase. Reading about triggers and change streams was a good start.

Let's answer them one by one so we have a clear picture of the solution.

**How do we know when something happens in the servers running individually? Both internally within a server and externally in the database.**

We can either allow the server to post events over HTTP or WebSocket. WebSocket is the better choice in general, since it keeps the connection open and lets the server push events without the client having to ask for them. In this case, though, we won't use WebSocket, because we want to avoid open connections to the dashboard from other services. A simple HTTP *POST* request to the dashboard is enough to send an event.

This makes it possible for an application to inform the dashboard about events that happen in the server. Think of it as events being outboxed from the server.

Outside the server, we can use a change stream to listen for changes in the database. This is a good way to know when something happens there.


**As a super admin, the specific actions worth tracking can change over time. Should we support dynamically configurable notification settings, or just create a set of notification settings supported by default?**

Assume there is a super admin in charge of assigning roles to users (an existing feature in the dashboard).
We can also let the super admin configure the notification settings used to notify users about events in the server or database. This is the better option because it spares us from updating notifications manually through a bootstrap script, and gives us an interactive interface for configuring them instead.

**What advantage does the database really give us, so we can easily know what is going on right at that level?**

With triggers and change streams, we can see events as they happen in the database, tracking the operations it receives straight from the application: updates, deletes, inserts, and so on.


With those questions answered to some extent, we can start designing the solution.

### Rules are the starting point

Starting with notification rules is perhaps the best way to go, since drafting rules keeps us focused on the properties that actually solve the problem. One interesting thing about drafting a schema is that it helps us identify who gets the message, who sends it, what it is about, and much more.

Let's draft a schema for the notification rules.
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

This schema is a simple one that can be used to notify users about events that happen in the server or database.

- `_id`: The unique identifier for the notification rule.
- `event`: The event that triggers the notification.
- `conditions`: The conditions that must be met for the notification to be sent.
- `audience`: The audience that receives the notification.
- `requiredPermission`: The permission a user must have to receive the notification.
- `mode`: The mode of the notification.
- `allowedChannels`: The channels allowed for the notification.
- `defaultChannels`: The default channels for the notification.
- `excludeActor`: Whether to exclude the actor from the notification.
- `enabled`: Whether the rule is active. Only enabled rules are monitored.

> In my opinion, the important part of this schema is that it ignores noise and focuses on the simplicity of what is needed at the moment, and this schema answers that.

With this schema, all we need to do is support **GET**, **POST**, **PUT**, and **DELETE** operations for the notification rules. It is also important to support pagination when fetching them.


### Subscription is how users opt in to receive notifications

One important thing to note is that notification rules are not the same as notification subscriptions. Rules determine when a notification should be sent. Subscriptions determine which notifications should be sent to which users.

A notification subscription looks like this:

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
Essentially, a subscription is a relationship between a user and a notification rule. It is what lets us decide which notifications go to which users.

### How do we know when a notification should be sent?

To know when a notification should be sent, we need to register enabled notification rule's collection for monitoring against the database. For that, we need a background worker system that registers consumers to track the various notification intents. It will be lovely to pick a well-tested, reliable library to help with this, and BullMQ is a good choice.

Let's set up a quick, representative version of how it will look:

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

The code sample above simply loads the consumers as a background worker system. Each consumer is specific to what it ought to do.

The workers need to consume messages from a queue and process them, and we don't have one set up yet, so let's create it.

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

One line in the worker bootstrap does subtle but important work in making sure we get notified when something happens: `await watchSources(logger).catch(() => null);`. It is responsible for setting up and updating a watchlist of enabled notification rules, which is what lets us send notification events to subscribed dashboard users.

A quick look at how it works would be good, but first, a few points that will make our life easier. Monitoring database changes can be done in two ways:

1. Using change streams
2. Using triggers

A change stream is a MongoDB feature that lets us monitor database changes in real time, which makes it a good way to know when something happens in the database.

Triggers also let us monitor database changes in real time, but they have to be created on the MongoDB Atlas service, which is a bit more complex and not as flexible as a change stream when integrating with an application.

> Triggers work well for isolated use cases, while change streams work well for application-to-database interaction.

Coming from a language like Go, one has the luxury of using goroutines to handle concurrent operations. That is not the case with JavaScript, so we need to be careful about how we handle concurrency. Still keeping the idea from Go, we use a ticker that runs at a fixed interval to check for changes in the database.
To handle contention, we track processing time and delay across queues so we don't overwhelm the system, and when a queue is falling behind, we push work over to other queues to reduce the delay. Interestingly, this is one of the approaches operating systems use to handle concurrent operations.

Tracking a checkpoint is also important, so we avoid reprocessing the same data over and over. It is another way to keep from overwhelming the system.

There is one more problem I haven't talked about yet: servers scaling up and down elastically. How do we ensure that the interaction between notification rules and change streams stays synchronised, without chaos? The answer is a single-leader Redis lock, implemented with a Lua script, so that only one instance of the application processes the queue at a time.

A helper for that in Sails can look like this:
```javascript
const ACQUIRE = `
local current = redis.call('GET', KEYS[1])
if current == false then
  if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'EX', ARGV[2]) then
    return 1
  end
  return 0
end
if ARGV[3] == '1' and current == ARGV[1] then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
  return 1
end
return 0
`;

const RELEASE = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
`;

module.exports = {

  friendlyName: 'Notification redis lock',

  description: 'Acquire or release a Redis lock. Renew only when the token already owns the key.',

  inputs: {
    key: {
      type: 'string',
      required: true
    },
    token: {
      type: 'string',
      required: true,
      description: 'Value stored in the lock. Release deletes the key only when it still holds this token.'
    },
    ttlSeconds: {
      type: 'number',
      description: 'Lock lifetime in seconds. Required when acquiring.'
    },
    renew: {
      type: 'boolean',
      defaultsTo: false,
      description: 'Refresh the TTL when this token already owns the key.'
    },
    release: {
      type: 'boolean',
      defaultsTo: false,
      description: 'Delete the key when it still holds this token.'
    }
  },

  fn: async function ({ key, token, ttlSeconds, renew, release }) {
    const redis = await sails.helpers.notifications.redisClient();
    if (!redis) { return null; }

    if (release) {
      const removed = await redis.eval(RELEASE, {
        keys: [key],
        arguments: [token]
      }).catch((err) => {
        sails.log.error('notifications:lock', err.message);
        return null;
      });
      if (removed === null) { return null; }
      return removed === 1;
    }

    const ttl = Math.floor(Number(ttlSeconds));
    if (!ttl || ttl < 1) { return null; }

    const claimed = await redis.eval(ACQUIRE, {
      keys: [key],
      arguments: [token, String(ttl), renew ? '1' : '0']
    }).catch((err) => {
      sails.log.error('notifications:lock', err.message);
      return null;
    });
    if (claimed === null) { return null; }
    return claimed === 1;
  }
};
```

The `ACQUIRE` script claims the lock only when the key is free, or renews it when the same token already owns it. The `RELEASE` script deletes the key only when the token still matches. This stops one instance from releasing or extending a lock that another instance holds.

With a single leader guaranteed, `watchSources` can safely own the change streams and the ticker, which is where we pick up next.

Let's take a look at how `watchSources` works.

```javascript

async function watchSources(logger) {
  const redis = await sails.helpers.notifications.redisClient();
  if (!redis) {
    logger.error('watcher.noRedis');
    return null;
  }
  const id = nodeId();
  let stopped = false;

  async function leader() {
    const claimed = await sails.helpers.notifications.redisLock.with({
      key: 'notification-watcher-lock',
      token: id,
      ttlSeconds: 30,
      renew: true
    });
    return claimed === true;
  }

  async function tick() {
    if (stopped) {
      return;
    }
    const isLeader = await leader();
    if (!isLeader) {
      await closeMissing(new Map());
      return;
    }
    const rules = await NotificationRule.find({ enabled: true, deletedAt: null }).catch(() => null);
    if (!rules) { return; }

    const watchTargets = pairsFromRules(rules);
    await closeMissing(watchTargets);
    const keys = Array.from(watchTargets.keys());
    for (let index = 0; index < keys.length; index++) {
      if (streams.has(keys[index])) {
        continue;
      }
      await openWatch(watchTargets.get(keys[index]), logger).catch((err) => {
        logger.error('watcher.openFailed', { err: err.message });
        return null;
      });
    }
  }

  const timer = setInterval(() => {
    tick().catch((err) => logger.error('watcher.tickFailed', { err: err.message }));
  }, sails.config.custom.constants.notificationWatcherInterval);
  await tick();
  return {
    stop: async () => {
      stopped = true;
      clearInterval(timer);
      await closeMissing(new Map());
      const openClients = Array.from(clients.values());
      for (let index = 0; index < openClients.length; index++) {
        await openClients[index].close().catch(() => null);
      }
      await sails.helpers.notifications.redisLock.with({
        key: 'notification-watcher-lock',
        token: id,
        release: true
      }).catch(() => null);
    }
  };
}
```

The point is the ticker fires at set intervals to check for fresh notification rules and also extract the collection to monitor via change streams. The `closeMissing` function closes any open change streams that are no longer needed, and the `openWatch` function opens a new change stream for the collection. `pairsFromRules` on the otherhand as a function extracts the collection to monitor from the notification rules.

> Notice how we use a single leader to manage the change streams and the ticker. This is important to ensure that the interaction between notification rules and change streams stays synchronised, without chaos.

A sneak peek at how `openWatch` works:

```javascript

async function openWatch(pair, logger) {
  const database = await mongoDb(pair.source);
  if (!database) {
    logger.warn('watcher.noDatabase', { source: pair.source });
    return null;
  }
  const stored = await ChangeStreamToken.findOne({ source: pair.source, collection: pair.collection }).catch(() => null);
  const options = { fullDocument: 'updateLookup' };
  if (pair.rules) {
    options.fullDocumentBeforeChange = 'whenAvailable';
  }
  if (stored && stored.resumeToken) {
    options.resumeAfter = stored.resumeToken;
  }
  const stream = database.collection(pair.collection).watch([], options);

  stream.on('change', (change) => {
    const handled = pair.rules ? invalidate(change) : publishChange(pair, change);
    handled.catch((err) => logger.error('watcher.changeFailed', { err: err.message, source: pair.source }));
  });
  stream.on('error', (err) => {
    logger.error('watcher.streamFailed', { err: err.message, source: pair.source, collection: pair.collection });
    stream.close().catch(() => null);
    streams.delete(watchKey(pair.source, pair.collection));
  });
  streams.set(watchKey(pair.source, pair.collection), stream);
  logger.info('watcher.open', { source: pair.source, collection: pair.collection });

  return stream;
}

```

First, for every rules ever created, we need to track them with change stream event registration and also store the resume token for the change stream. The resumption token is always updated during the change stream event handling.The line `const handled = pair.rules ? invalidate(change) : publishChange(pair, change);` is the key to the whole process. This ensures that even when the servers go down, the change stream will be resumed from the last known position.

You can say this, "If the rule is enabled, invalidate the cache, otherwise publish the change." This only happens on startup afterward incoming data change is matched against the most recent notification rule.

The article is getting a bit long, so let's wrap it up here and continue in another one focusing on how incoming change stream information are processed between queues to ensure appropriate notification is sent to the appropriate users.

