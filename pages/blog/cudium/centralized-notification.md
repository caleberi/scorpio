---
title: 'Centralized notification system for Cudium'
summary: 'A centralized notification system for Cudium that can send notifications via email, SMS, and push notifications.'
authors:
  - 'Adewole Caleb'
date: '2026-08-19'
topics:
  - 'Cudium'
  - 'Engineering'
  - 'Notifications'
  - 'Javascript'
  - 'NodeJs'
  - 'Sails Js'
  - 'Firebase'
  - 'Email'
  - 'SMS'
  - 'Push Notifications'
  - 'Centralized Notification'
  - 'Abstraction'
image: '![image](../../../blobs/cover11.png)'
---

> Imagine having a whole abstraction capable of sending email, SMS, or notification to all your users in one place .
> 
> Prerequisite : Knowledge of either Javascript, (ExpressJs or Sails Js) and NodeJs .

Abstraction, What does it mean?

[Abstraction](https://en.wikipedia.org/wiki/Abstraction_\(computer_science\)) according to computing is the process of generalising or hiding concrete details of a functionality to focus attention on more information of greater importance. It can also be explained as hiding away from the low-level functionality of a feature and exposing it via function or API so that it can be consumed.

In programming, whenever you find yourself repeating the same code or logic, it's a good idea to create an abstraction. This is called the "Do not repeat yourself" rule (DRY). This means you take the detailed parts of the code and hide them, making it easier to use and understand. For example, instead of writing the same email-sending code in multiple places, you can create a function that handles it. This way, you only need to call the function whenever you need to send an email. This makes your code cleaner and easier to maintain.

## Firebase Cloud Messaging Feature

As a case study, a while back at Cudium, I needed to integrate notification into our application so that when a user makes a transaction, they are properly notified about the deposit or withdrawal made on their wallet via email and also via a notification so I decided to integrate with firebase after a few days of research.

One thing stood out during my research, I needed to support two things :

1.  Cross-platform notification - Android, Web and iOS. All of which Firebase Cloud Messaging (FCM) support
    
2.  Support unicast, broadcast and also topic base subscription
    

Since all the libraries I use at work are built on top of [Express JS](https://expressjs.com/), they help avoid bootstrapping Express applications from scratch, Sails JS, I mean, which is another form of abstraction. I decided to write a helper file to support this. Think of it as a utility library function, but in Sails JS, it goes beyond that. Let's take a look at it and develop an interesting approach that will help us create a 3-in-1 abstraction for centralized notifications later.

> While the idea is language agnostic, I will be using Javascript to explain.

Let's start with setting up the configuration for the Firebase cloud message which allows us to import all necessary constants

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1717931241558/e3e44237-5f5f-4b9a-ab30-3dfa8aa5b6ca.png align="center")

> \*All configurations specific to Firebase is extracted from the docs at \*[*https://firebase.google.com/docs/cloud-messaging*](https://firebase.google.com/docs/cloud-messaging). Ensure you have the Firebase admin library installed

Extracting the configuration is not the only thing needed to set up a Firebase cloud message notification on the backend, you also need to initialise the Firebase itself to be able to use it like so

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1717931649940/38fe5c47-1d29-4412-8cad-37f30a798488.png align="center")

Sails allows us to specify the type of data we expect to be passed into our functions or controllers but the way, arguments are specified to function in Sails Js is via property specification in this case for us to be able to set Firebase notification as a helper/util library we need to specify some expectation for the argument that the Firebase cloud message library expects to properly send notification across supported platforms such as device token, data, title, body, priority, time to live, topic, mutableContent, contentAvailable e.t.c. To do this, we need to specify the arguments in a table, which are expressed as a JavaScript object following Sail's JS conventions. You can see how they are defined [here](https://sailsjs.com/documentation/concepts/helpers#?inputs).

| **Input** | **Type** | **Description** | **Defaults To** | **Example** |
| --- | --- | --- | --- | --- |
| `fcmDeviceTokens` | JSON | An array of unique FCM notification tokens for each device |  | `['<token_1>']` |
| `data` | JSON | Data to send to the client for the notification | {} | `{"account": "savings", "amount": 900.0}` |
| `title` | string | Push notification title on delivery | `""` | `Debit Alert` |
| `body` | string | Push notification message body on delivery | `""` | `msg: A deposit has been made to your account` |
| `contentAvailable` | boolean | Used when sending messages to iOS | `true` |  |
| `mutableContent` | boolean | This applies only on iOS to allow the device to mutate the content before the presentation | `true` |  |
| `priority` | string | The delivery priority value for the target audience (allowed values: `high`, `normal`) | `PRIORITY` |  |
| `timeToLive` | number | Time in seconds to hold the message if the device is offline | `TIME_TO_LIVE` |  |
| `topic` | string | Topic to broadcast to | `""` |  |

> Side note: In order to be able to send notification to users, I needed to map every user to assigned device token as shown in the code snippet below, but since I am only focused on explaining how to bundle sms, fcm and email message as a unit library, I won't be talking about the mapping user to ensure unique messaging even when users change their devices but , this snippet below gives a rough idea of what it is.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1717933561030/e4f5fe76-e03d-4fe1-b70a-9921aad11ad6.png align="center")

Now back from our little detour, I will share the code snippet for the FCM notification and then explain what it does. Let's go.

```javascript
async function ({ fcmDeviceTokens, data, title, body, priority, timeToLive, topic, mutableContent, contentAvailable }) {

    if(( !topic && !fcmDeviceTokens) || !data || !title || !body) {
      return false;
    } // guard against missing required input

    let notified = false;

    const payload = { data, notification: { title, body } };

    const defaultMessageOpts = {
      ttl: timeToLive || TIME_TO_LIVE,
      priority: priority || PRIORITY,
    };

    try {
      if (!Array.isArray(fcmDeviceTokens)) {
        fcmDeviceTokens = [fcmDeviceTokens];
      }
      const shouldBroadcastToTopic = !!topic && !!mutableContent && !!contentAvailable;
      const shouldUseUnicast = fcmDeviceTokens.length === 1 && !shouldBroadcastToTopic;
      const shouldUseMulticast = fcmDeviceTokens.length > 1 && !shouldBroadcastToTopic;
      /**
       * The section of code below includes a backoff alogrithm in case of messages not
       * been sent to  FCM backend for notification delivery . The internal code block
       * figures out which mode of delivery to use [ subscription, unicast, multicast ]
       */
      for ( let retryCount = 0; retryCount < MAX_NOTIFICATION_BACKOFF && !notified; retryCount++ ) {
        // handle unicast
        if(shouldUseUnicast) {
          const response = await fireBaseAdmin.messaging().send({
            token: fcmDeviceTokens[0],...payload,
            android: { ...defaultMessageOpts }
          });

          if(typeof response === 'string') {
            sails.log('Unicast-notification-sent: ', response, ' for ', fcmDeviceTokens);
            notified = true;
          }
          !notified && (sails.log('Unicast-notification-retry: atempt ', retryCount + 1, ' for ', fcmDeviceTokens));
        }// end of handle unicast
        // handle multicast
        if(shouldUseMulticast) {
          const response = await fireBaseAdmin.messaging().sendEachForMulticast({
            token: fcmDeviceTokens, ...payload,
            android: { ...defaultMessageOpts },
          });
          const successCount = Number(response.successCount);
          sails.log('multicast-notification-sent:', successCount, ' of ', fcmDeviceTokens.length, ' sent' );
          // there are tokens that failed, let's collate them and send again
          notified = successCount=== fcmDeviceTokens.length;
          if(!notified) {
            const retryDeviceToken = response.responses.map((sendResponse, index) => {
              if(!sendResponse.success){
                return fcmDeviceTokens[index];
              }
              return null;
            });

            fcmDeviceTokens = _.compact(retryDeviceToken);
            sails.log('multicast-notification-sent-retry: attempt ',retryCount + 1, ' for ', fcmDeviceTokens.length, ' tokens to retry' );
          }
        } // end of handle multicast
        // handle broadcasting to topics
        if(shouldBroadcastToTopic) {
          const response = await fireBaseAdmin.messaging().sendToTopic(topic, payload, {...defaultMessageOpts,  mutableContent, contentAvailable});

          if(response.messageId){
            sails.log('topic-notification-broadcast-sent: ', topic);
            notified = true;
          }

          !notified && (sails.log('topic-notification-broadcast-retry: attempt ',retryCount + 1, ' for ', topic));
        } // end of handle broadcasting to topics
      }
      sails.log('**************** FCM-notification: all done ************************');
      return notified;
    } catch (err) {
      sails.log( 'FCM-notification-error: ', err.message);
      return false;
    }
  }
```

With the parameters specified above, designing a helper function to abstract the implementation details of all things notification was easy.

First, the implementation starts with a guard clause to ensure all required parameters are provided. If any of `topic`, `fcmDeviceTokens`, `data`, `title`, or `body` are missing, the function returns `false` immediately. Then the `payload` , an object was built including the data and notification content (title and body). Default message options (`defaultMessageOpts`) such as `ttl` (time-to-live) and `priority` are set using the provided values or default constants (`TIME_TO_LIVE` and `PRIORITY`). This is what is passed over to the Firebase notification SDK.

Secondly, the main focus was on figuring out whether the notification was of one of the three modes listed below :

*   **Unicast**: Sending a notification to a single device.
    
*   **Multicast**: Sending notifications to multiple devices.
    
*   **Broadcast to Topic**: Sending notifications to all devices subscribed to a specific topic.
    

To determine this, the following conditions were used :

*   **Unicast**: If there's only one device token and no broadcasting topic.
    
*   **Multicast**: If there are multiple device tokens and no broadcasting topic.
    
*   **Broadcast to Topic**: If a topic is provided along with `mutableContent` and `contentAvailable`.
    

Since sending notifications can fail, I wanted to ensure we retry sending a notification even after a failure. To achieve this, a loop was used to implement a retry mechanism with a backoff strategy, attempting to send the notification up to `MAX_NOTIFICATION_BACKOFF` times if not successful.

For unicast mode, a notification is sent to a single device token. If the response is successful, `notified` is set to true; otherwise, a retry attempt message is logged. For multicast mode, notifications are sent to all device tokens using `sendEachForMulticast`. The number of successfully sent notifications is logged, and if not all are successful, the failed tokens are identified. The list is compacted to remove null values, and retries are made for the failed tokens. For broadcasting to a topic, notifications are sent to devices registered to the specified topic. If the response contains `messageId`, it is marked as successful and `notified` is set to true; otherwise, a retry attempt message is logged.

With this, we have the Firebase utility ready to support all three modes of notification. Now, let's set up the email side of things.

## Email Notification Feature

Many applications need an email support feature and you can integrate any email service based on your software requirements. For this article, I chose to integrate with Zoho Mail, even though the previous integration was with SendGrid to ensure backward compatibility.

```javascript
const nodemailer = require('nodemailer');
const hbs = require('nodemailer-express-handlebars');
const nodemailerSendgrid = require('nodemailer-sendgrid');
const {zohoHost,zohoEmailUser,zohoEmailPassword} = sails.config.custom.zohoEmailCredentials;
const complierOpts = {
  viewEngine: { 
    extName: '.hbs',partialsDir: './views',
    layoutsDir: './views/layouts', defaultLayout: 'main.hbs',
    helpers: { logo() {return 'http://logo.png';}}
  },
  viewPath: './views/',
  extName: '.hbs'
};

const zohoTransporter = nodemailer.createTransport({
  host: zohoHost, service: 'Zoho',
  port: 465, secure: true, // use SSL
  auth: { user: zohoEmailUser, pass: zohoEmailPassword},
  tls: { rejectUnauthorized: false }
}).use('compile', hbs(complierOpts));

const sendGridTransporter = nodemailer.createTransport(nodemailerSendgrid({
  apiKey: sails.config.custom.sendgridSecret
})).use('compile', hbs(complierOpts));

const transporters = [zohoTransporter, sendGridTransporter];

module.exports = {
  friendlyName: 'Send email',
  description: 'Send email to respective user',
  inputs: {
    options: { type: 'ref', required: true},
    from: { type: 'string', required: true}
  },
  exits: {
    success: { description: 'All done.'}
  },
  fn: async function({ from,options}) {
    let isEmailSucessfullySent = false;
    for (let idx = 0; idx < transporters.length && !isEmailSucessfullySent; idx++) {
      try {
        const transporter = transporters[idx];
        const emailOptions = { from,...options};
        await transporter.sendMail(emailOptions);
        isEmailSucessfullySent = true;
      } catch (error) {
        sails.log('Send-email-failed:', error.message);
        isEmailSucessfullySent = false;
      }
    }
    return isEmailSucessfullySent;
  }
};
```

By listing all the supported email providers in the code above, the application ensures reliable email delivery by using multiple transporters: Zoho Mail and SendGrid. The email payload, combined with a flexible template configuration, allows the application to easily integrate and send well-formatted emails.

Let's quickly move to SMS notifications before discussing the centralized notification code.

## Sms Notification Feature

To send notifications, we configure an Axios instance to make HTTP POST requests to the SMS provider. This ensures delivery to users whenever a pin or token is needed, as shown in the code snippet below.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1717945035912/f5c7aa41-963b-4a44-83f1-507bf2009837.png align="center")

So with these three utility functions, let's create a centralized notification function that can send notifications via the three channels depending on varying configurations.

## Centralized Notification

To centralize SMS, FCM, and Email notifications into a single utility function, we made some basic assumptions. We need to specify the type of notification to send and the necessary payload. This allows us to create a generalized function that builds on the three notification features discussed earlier.

```javascript
const ALL = 'all';
const EMAIL = 'email';
const PUSH = 'push';
const SMS = 'sms';
const pushTemplate = sails.config.custom.notificationMessage;
const notificationsAllowed = ['sms','email', 'push', 'all'];

module.exports = {
  friendlyName: 'Notification center',
  description: '',
  inputs: {
    templateOption: {
      type: 'ref',
      description: 'An object for providing push and email template option',
      example: { push: 'template-name', email: 'template-name' }
    },
    data: {
      type: 'ref',
      required: true,
      description: 'An object for providing push and email template option',
      example: { push: {}, email: {}, sms:{} }
    },
    notification: {
      type: 'string',
      required: true,
      description: 'notifications to send',
      isIn: notificationsAllowed
    },
    recipientId: {
      type: 'string',
      required: true,
      description: 'User receiving the email or push notification',
    }
  },
  exits: {
    success: {
      description: 'All done.',
    },
  },
  fn: async function ({ templateOption, data, notification, recipientId: userId }) {
    const { sendEmail, mapFcmDeviceToken, sendFcmNotification, parseNotificationMessageTemplate , sendSms } = sails.helpers;
    const user = await User.findOne({ id: userId }).select(['email', 'firstName']);
    const { email, firstName } = user;
    const name = firstName[0].toUpperCase() + firstName.slice(1);

    if (notification === ALL || notification === EMAIL) {
      const template = templateOption[EMAIL];
      const emailData = data[EMAIL];
      if (!template || !emailData) {
        sails.log('Notification-center-email-error:templateOption and data.email is required for sending email');
        return;
      }

      const { subject, from, ...context } = emailData;
      context.name = name;
      const emailSent = await sendEmail.with({ from, options: { to: email, subject, template, context } });
      sails.log('email-sent-success to ', email, 'is', emailSent);
    }

    if (notification === ALL || notification === SMS) {
      const smsData = data[SMS];
      const smsSent = await await sails.helpers.sendSms({
          message: smsData.message
          phoneNumber: smsData.phoneNumber
      });
      sails.log('sms-sent-success to ', smsData.phoneNumber, 'is', smsSent);
    }

    if (notification === ALL || notification === PUSH) {
      const templateType = templateOption[PUSH];
      const tmplData = data[PUSH];
      if (!templateType || !tmplData) {
        sails.log('Notification-center-email-error:templateOption and data.push is required for sending push notification');
        return;
      }

      const useTemplate = pushTemplate[templateType];
      const isMapped = await mapFcmDeviceToken.with({ userId });
      if (isMapped) {
        const { token: fcmDeviceTokens } = isMapped;
        const { body: tmpl, title } = useTemplate;
        const { transactionType, ...contextData} = tmplData;
        contextData.name = name;
        const notificationBody = await parseNotificationMessageTemplate.with({ tmpl, tmplData: contextData });
        const dataPayload = {};
        if(transactionType){
          dataPayload.transactionType = transactionType;
        }
        if(contextData.currency){
          dataPayload.currency = contextData.currency;
        }
        const pushSent =  await sendFcmNotification.with({ fcmDeviceTokens, title, body: notificationBody, data: dataPayload });
        sails.log('push-sent-success to ', fcmDeviceTokens, 'is', pushSent,' Data:', tmplData);
      }
    }
  }
};
```

The centralized notification library in the snippet above is designed to send emails, SMS, and push notifications to users. It starts by setting up constants for different notification types and allowed notifications. The required inputs include template options, data for the templates, the type of notification to send, and the recipient's user ID.

When the function runs, it first gets the user's email and first name using the provided user ID. For email notifications, if the notification type is 'ALL' or 'EMAIL', it creates the email using the given template and data, sends it, and logs the result. Similarly, for SMS notifications, it checks if the type is 'ALL' or 'SMS', and sends an SMS with the provided data.

For push notifications, if the type is 'ALL' or 'PUSH', it retrieves the appropriate template and data, maps the user's FCM device tokens, and constructs the push notification message. The message is then sent.

The library ensures each notification type is only attempted if the required data and templates are provided, and logs errors if any data is missing. It uses necessary helper functions to handle the sending process, ensuring a robust and flexible notification system. This approach guarantees that notifications are reliably sent through multiple channels, enhancing user communication.

While this may seem like a lengthy process for sending notifications, emails, or SMS to users, it ensures that each component can work independently and also together.

One example of how this can be applied is during the KYC process for a new user, as shown in the snippet below.

```javascript
 await sails.helpers.notificationCenter.with({ notification: 'all', recipientId: id,
    data: {
        push : { updateProfile: true },
        email : { subject,from: mailFrom }
    },
    templateOption: {
        push: kycCompletedSuccessfully ? USER_ID_VERIFICATION : USER_ID_VERIFICATION_FAILED ,
        email: template
    }
});
```

A similar use case could be for sending out transaction notifications to users after a debit or credit process.

> While I know this article does not real give you the in depth step by step process of writing this whole logic out . My hope is that it gives you an idea of how you can set up all notification related logic in one library and use it at will.

In summary, I hope this article lays in your heart the importance of abstraction using function and how to build better software with it

Resources:

*   [https://sailsjs.com](https://sailsjs.com/)
    
*   [https://en.wikipedia.org/wiki/Abstraction\_(computer\_science)](https://en.wikipedia.org/wiki/Abstraction_\(computer_science\))
    
*   [https://firebase.google.com/docs/cloud-messaging](https://firebase.google.com/docs/cloud-messaging)
    