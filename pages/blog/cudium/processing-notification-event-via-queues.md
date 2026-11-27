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

Right before we start, let' create a quick visualization video to help us understand the flow.
<video src="../../../blobs/change-stream-to-notification-event.mp4" controls></video>

From the visualization video, we can see that breaking down flow make it easy to understand the moving parts.

### Ingesting data into the system

Given the fact that data consumption is a critical and foundational part of the system. This is an entry point for the system and the first step in the data processing pipeline. Ingestion can support in two ways:

1. **Webhook**: The system can be configured to receive webhook notifications from external services. When an event occurs, the external service sends a POST request to the system's webhook endpoint, triggering the ingestion process. Idempotency is guaranteed by the webhook endpoint.

2. **Change Stream**: The system can monitor the database for changes using change streams. When a change occurs, the system captures the event and processes it accordingly.

For this article, look at both approaches.
