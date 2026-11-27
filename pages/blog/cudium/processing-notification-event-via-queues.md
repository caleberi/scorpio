---
title: 'Processing Published Change Stream As Notification Event'
summary: 'Flow process for moving incoming change stream data as notification event.'
authors:
  - 'Adewole Caleb'
date: '2026-11-25'
topics:
  - 'Cudium'
  - 'Engineering'
  - 'Queues'
  - 'MongoDb'
  - 'Dashboard'
  - 'Sails Js'
  - 'Email'
  - 'Socket.io'
  - 'Slack'
  - 'Web Push Notifications'
image: '![image](../../../blobs/cover62.webp)'
---

## An Event Came In, The Factory Must Process

Last article [Notification via Change Stream for Dashboard Updates](/blog/cudium/notification-via-change-stream-for-dashboard-updates) covered the idea of watching database changes via change stream and processing them as enqueued events. In this article, we will look at what the processing line for the events looks like.

Right before we start, let' create a quick architecture diagram to help us understand the flow.
<video src="../../../blobs/change-stream-to-notification-event.mp4" controls></video>

