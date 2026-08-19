---
title: 'Integrating two-factor authentication for Cudium'
summary: 'A guide to integrating two-factor authentication for Cudium.'
authors:
  - 'Adewole Caleb'
date: '2026-08-19'
topics:
  - 'Cudium'
  - 'Engineering'
  - 'Two-factor authentication'
  - 'Javascript'
  - 'NodeJs'
  - 'Sails Js'
  - 'Firebase'
  - 'Email'
  - 'SMS'
  - 'Push Notifications'
  - 'Centralized Notification'
  - 'Abstraction'
image: '![image](../../../blobs/cover12.jpeg)'
---
> Prerequisites: Database knowledge, JavaScript, Node.js (Express.js or Sails.js), and a bit of curiosity

He (CTO) talked, and I listened.

That's not entirely true 🤭. We discussed it, but I suggested writing a POC before implementing it in the codebase.

# POC?

According to Wikipedia, [**Proof of concept** (**POC** or **PoC**](https://en.wikipedia.org/wiki/Proof_of_concept)), also known as **proof of principle**, is a way to show that an idea, method, or principle can work. It demonstrates feasibility or viability, aiming to verify that a concept or theory has practical potential. A proof of concept is usually small and may not be fully complete.

In this article, I will discuss how a simple POC can help your development process by building intuition about a feature and collecting data through experimentation. All this is about securing your application with two-factor authentication.

With that said, Let's jump right into it.

## **OTPs?**

A password that is valid for only one login session or transaction on a computer system or other digital device is called an OTP [(one-time password)](https://en.wikipedia.org/wiki/One-time_password). It is sometimes called a dynamic password, one-time PIN, or one-time authorization code (OTAC). Many implementations also use two-factor authentication, ensuring that the one-time password requires both something a person knows (like a PIN) and something they have (like a keyring fob with an OTP calculator, a smartcard, or a specific cellphone). This way, OTPs avoid many of the issues associated with traditional (static) password-based authentication.

OTP generation algorithms also use cryptographic hash functions—which may be used to derive a value but are difficult to reverse, making it impossible for an attacker to access the data that was used for the hash—as well as pseudorandomness or randomness to generate a shared key or seed. If this weren't the case, it would be simple to forecast future OTPs by looking at past ones.

Often as a series of characters, a password as confidential information is used to verify a user's identity. Passwords were traditionally meant to be memorized, however, it might be difficult to learn the different passwords for every service the average person uses due to the sheer amount of password-protected services they use.

> ***It has been suggested that OTPs could supplement conventional passwords in addition to possibly replacing them. The drawbacks are that physical tokens can be misplaced, broken, or stolen, and OTPs might be intercepted or redirected. Since many OTP-using systems do not use them securely, attackers can still obtain the password and employ phishing attacks to pretend to be the authorized user.***

Most modern applications, strongly support the use of OTPs with authenticators to facilitate user verification - (authorization & authentication).

## Authentication via an Authenticator?

Authentication is a process used to verify a user's identity by requiring one or more distinctive factors. These factors can fall into different categories :

1.  **Something You Have**: This is a physical object unique to the user, such as a smartphone, a security token, or a smart card.
    
2.  **Something You Know**: This is information only the user knows, like a PIN, password, or security question answer.
    
3.  **Something You Are**: This involves biometrics, such as fingerprints, facial recognition, or iris scans, which are unique to the individual.
    

An authenticator, on the other hand, verifies a user's identity by utilizing the factors listed above.

In this article, we will discuss using an authenticator as a physical object unique to a person to verify a user's identity.

We need to make a few assumptions to keep this article as short as possible,

1.  There is a user model setup for our use case. A typical example in Sails js
    
    is shown below :
    
    ```javascript
    module.exports = {
      tableName: 'users',
      attributes: {
        firstName: { type: 'string' },
        lastName: { type: 'string'},
        middleName: { type: 'string', allowNull: true},
        email: { type: 'string',required: true, unique: true,isEmail: true,},
        password: {type: 'string',required: true},
        twoFASecret: { type: 'string',description: 'The secret embeded in the 2FA code'},
        twoFAEnabled:{ type: 'boolean',defaultsTo:false},
        twoFAEmailToken:{ type: 'string',description: 'The email verification token for 2fa'},
        twoFAEmailTokenTTL: { type: 'string',columnType: 'datetime',},
     }
    }
    ```
    
2.  User registration and login have been set up with which users can be authenticated using factor two above i.e the password
    

With this assumption, we can proceed to implement a two-factor authentication feature for our application.

### Setup Two Factor Code

Let's start by importing the necessary packages and constants for our two-factor setup endpoint. We are using the `speakeasy` library to save time on writing a one-time passcode generator. This library is ideal for two-factor authentication and supports Google Authenticator and other two-factor devices. It is well-tested and includes robust support for custom token lengths, authentication windows, hash algorithms like SHA256 and SHA512, and other features. It also includes helpers like a secret key generator.

```javascript
const speakeasy = require('speakeasy');
const { resendWaitTime, tokenExpiredIn } = sails.config.custom.constants;
// The name to be display on the authentication after authentication
const appName = "Test-application";
```

Next, we will set up our request handler endpoint in Sails.js to add our business logic.

```javascript
module.exports = {
  friendlyName: 'Create two factor code',
  description:
    'generate a qrl image and code  details for a loggedin user for subsequent authentication',
  inputs: {}, 
  exits: {
    success: { statusCode: 200,description: 'A qrl image and code have been sent'},
    serverError: { statusCode: 500,description: 'Something went wrong'},
    emailNotSent: {statusCode: 400,description: 'welcome message email not sent'},
  },
  fn: async function() { 
     // business logic goes here 
  }
}
```

So, for the business logic, we assume that our user has logged in and wants to upgrade their security settings to use an authenticator. We first check if they have already set up their two-factor authentication. If not, we use the `speakeasy.generateSecret` function to set it up and generate a QR image for easy setup, as shown below. It's important to send a token to the user's email to verify that they are the one who requested to set up their 2FA.

```javascript
async function() { 
   const user = this.req.user;

    if (user.twoFAEnabled) {
      const errorResponse = await sails.helpers.errorResponse.with({message: '2FA is already enabled'});
      throw { errorResponse: errorResponse };
    }
   
  const secret = speakeasy.generateSecret({
      name: appName,
      issuer: `.com.${appName}::engine`,
      otpauth_url: true,
      length: 20,
  });  
   
  const qrImage = await sails.helpers.generateQrImage.with({ url: secret.otpauth_url }); 
  if (!qrImage) {
     const errorResponse = await sails.helpers.errorResponse.with({
        message: 'Qrcode information could not be generated. please contact support'
     });

      throw { errorResponse: errorResponse };
    }

  const { token: twoFactorEmailToken, expiresAt: twoFactorEmailExpireAt } =
      await sails.helpers.generateToken.with({ minute: tokenExpiredIn });

   await User.update({ id: user.id }).set({
      twoFASecret: secret.base32,
      twoFAEmailToken: twoFactorEmailToken,
      twoFAEmailTokenTTL: twoFactorEmailExpireAt,
   });

  const emailSent = await sails.helpers.sendEmail.with({
      from: "from@email.com",
      options: { 
        to: user.email,
        template: 'two-fa-verification-email',
        subject: `Your Request For Two Factor Authentication Token - ${twoFactorEmailToken}`,
        context: { name: user.firstName,token: twoFactorEmailToken},
      },
 });

    if (!emailSent) {
      const errorResponse = await sails.helpers.errorResponse.with({
        message: 'Qrcode information could not be generated. please contact support'
      });
      throw { emailNotSent: errorResponse };
    }

    const { expiresAt: resendIn } = await sails.helpers.generateToken.with({minute: resendWaitTime});
    const successResponse = await sails.helpers.successResponse.with({
      message: 'Qrcode information generated successfully.',
      data: {
        image: qrImage,
        secret: secret.base32,
        expiresAt: resendIn
      },
    });

    return successResponse;
}
```

In the code above, here is a breakdown of the function imported from the helpers above

1.  `sails.helpers.errorResponse`
    
    *   Used to generate standardized error responses
        
    *   Called when 2FA is already enabled or when QR code generation fails
        
2.  `sails.helpers.generateQrImage` - we will discuss this below
    
    *   Generates a QR code image from the OTP URL
        
3.  `sails.helpers.generateToken`
    
    *   Used to generate tokens with expiration times
        
    *   Called twice: once for the email verification token and once for setting a resend timeout
        
4.  `sails.helpers.sendEmail`
    
    *   Sends an email with the 2FA verification token
        
    *   Uses a template for the email content
        
5.  `sails.helpers.successResponse`
    
    *   Generates a standardized success response
        
    *   Used to return the final result with a QR code image and other relevant data
        

### Generating QR Image

In the explanation above, we generated a QR code without showing how. So, in this section, let's explain how to do that by setting up the necessary imports below:

```javascript
const qrcode = require("qrcode");
const util = require('util');
const generator= util.promisify(qrcode.toDataURL);
```

So, we import `qrcode`, a library that helps us embed secret information into a QR image that our authenticator can scan.

```javascript
module.exports = {
  friendlyName: "Generate qr image",
  description: "",
  inputs: {
    url: { 
      type: "string",
      example: "otpauth://caleb@gmail.com?issuer=cudium",
      description: "url to embed into the qr image",
    },
  },
  exits: { success: { description: "All done." }},
  fn: async function ({ url }) {
    try {
      const image = await generator(url);
      return image;
    } catch (err) {
      return false;
    }
  },
};
```

Nothing too complicated above, just a couple of functions creating an image 🤓.

### Verify Two Factor Code

To finalize the process of setting up a two-factor for a user, we will create a basic endpoint that takes in the sent token to the user's email and the token from the scanned authenticator application on the front end which we will talk about in a short moment. Then we will use the `speakeasy.totp.verify` function to assert if the passed token from the app is valid with the secret stored for the user in the setup two-factor endpoint step.

```javascript
const speakeasy = require('speakeasy');
module.exports = {
  friendlyName: 'Verify otp login',
  description: 'Verify if otp code is correct.',
  inputs: {
    otp: {
      type: 'string',example: '395013',
      description: 'otp\'s authenticator code for verification',
    },
    emailToken: {
      type: 'string',example: '282842',
      description: 'token sent when verifying 2fa for the first time',
    },
  },
  exits: {
    success: {
      statusCode: 200,
      description: 'A qrl image and code have been sent',
    },
    invalidOrExpiredToken: {
      statusCode: 401,
      description:
        'The provided token is invalid, expired, or has already been used.',
    },
    serverError: {
      statusCode: 500,
      description: 'Something went wrong',
    },
  },
  fn: async function({otp,emailToken}){
   // business logic here
  }
}
```

Let's discuss the business logic, assuming the user is logged in and trying to complete the two-factor setup.

First, we try to extract all saved information that is related to the two factors in the previous section

```javascript
const user = this.req.user;
const { twoFAEnabled, email, twoFASecret,twoFAEmailTokenTTL } = user;
```

Maybe our user's `twoFAEmailTokenTTL` has expired 🧐. Let's test for that.

```javascript
if (emailToken){
    if (twoFAEmailTokenTTL <= Date.now()) {
      const errorResponse = await sails.helpers.errorResponse.with({
        message: '2FA Email token expired/invalid'
      });
    
      throw { invalidOrExpiredToken: errorResponse };
    }
}
```

We now verify the token provided is valid with `twoFaSecret` stored for the user.

```javascript
 const verified = speakeasy.totp.verify({
      secret: twoFASecret,
      token: otp,
      encoding: 'base32',
});

if (!verified) {
   const errorResponse = await sails.helpers.errorResponse.with({
     message: '2fa verification failed'
   });

   throw { invalidOrExpiredToken: errorResponse };
}
```

Then we can return a successful response to the user with the code below. Notice that we did not use a cache for the token to keep this article simple; instead, we kept everything in the model.

```javascript
if (!twoFAEnabled) {
      await User.update({ id: user.id }).set({
        twoFAEmailTokenTTL: '',
        twoFAEmailToken: '',
        twoFAEnabled: true,
      });

      successResponse.message = '2FA Authentication setup completely';
}

return successResponse;
```

Overall, here is what we have:

```javascript
async function({otp,emailToken}){
    const user = this.req.user;
    const { twoFAEnabled, email, twoFASecret,twoFAEmailTokenTTL } = user;
    if (emailToken){
        if (twoFAEmailTokenTTL <= Date.now()) {
          const errorResponse = await sails.helpers.errorResponse.with({
            message: '2FA Email token expired/invalid'
          });
          throw { invalidOrExpiredToken: errorResponse };
        }
    }

     const verified = speakeasy.totp.verify({
          secret: twoFASecret,
          token: otp,
          encoding: 'base32',
     });    

    if (!verified) {
       const errorResponse = await sails.helpers.errorResponse.with({
         message: '2fa verification failed'
       });
    
       throw { invalidOrExpiredToken: errorResponse };
    }
    
    if (!twoFAEnabled) {
          await User.update({ id: user.id }).set({
            twoFAEmailTokenTTL: '',
            twoFAEmailToken: '',
            twoFAEnabled: true,
          });
    
          successResponse.message = '2FA Authentication setup completely';
    }
    return successResponse;
};
```

### The Frontend

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1719884271768/65966606-a2cc-4619-a4ee-8c84bd8b2774.png align="center")

Still assuming the user is logged in, our endpoint in the setup section supports the screen displaying the QR code. Our input screen accepts the code from our token and email token. With this, we have our 2FA all set up.

> The overall code was generated as a **POC** and tested separately from the codebase to understand how the two factors work. A good video to check out is [this](https://www.youtube.com/watch?v=46AKWNOJ3-Y); it clearly explains how the authenticator itself works. Then it was adapted into the project with extra information.

To summarize what we've learned so far, let's discuss the pros and cons of using two-factor authentication.

**Pros:**

*   Enhanced security: Authenticator apps provide a significant security boost over SMS-based 2FA, offering better protection against phishing and SIM-swapping attacks.
    
*   Offline functionality: Most authenticator apps work without an internet connection, generating codes based on time and a shared secret.
    
*   Multiple account support: A single authenticator app can manage 2FA for numerous accounts across different services.
    

**Cons:**

*   Device dependency: If users lose or break their device, they may lose access to their accounts if proper backup measures aren't in place.
    
*   Setup complexity: Initial setup can be more complex than SMS-based 2FA, potentially deterring less tech-savvy users.
    
*   Synchronization issues: Time-based codes rely on the device's clock being accurate. Desynchronization can cause problems.
    
*   App vulnerabilities: If the authenticator app itself has security flaws, it could compromise the 2FA process.
    
*   Backup and transfer challenges: Moving to a new device or backing up 2FA setups can be complicated and vary between apps.
    
    ![Sample Image Of Google Authenticator](https://play-lh.googleusercontent.com/1c2quocIiaZtFYesmJbi8xuNS9Ai5ivAWRa4_NVivaM8gBEnZLcpKcqvldkw9XYv-A align="center")
    

> A key takeaway from this article is that you don't need to implement the entire functionality to understand how to build a feature. Focusing on the important component of the feature using a POC helps you grasp the main problem you are trying to solve.

In summary, I hope this article highlights the importance of POCs in software engineering and how they can help you develop features faster and better by understanding the key problem you are trying to solve.


Resources:

*   [https://www.youtube.com/watch?v=46AKWNOJ3-Y](https://www.youtube.com/watch?v=46AKWNOJ3-Y)
    
*   [https://en.wikipedia.org/wiki/Password](https://en.wikipedia.org/wiki/Password)
    
*   [https://en.wikipedia.org/wiki/One-time\_password](https://en.wikipedia.org/wiki/One-time_password)