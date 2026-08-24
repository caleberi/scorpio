---
title: "Effortless Cloudinary File Upload Management With Kloudinary"
summary: "Simplify Cloudinary uploads with Kloudinary Go library."
authors:
  - "Caleb Adewole"
date: "2026-08-19"
topics:
  - "Golang"
  - "Concurrency"
  - "Cloudinary"
  - "Uploader"
type: "Blog"
image: "![image](../../../blobs/cover17.webp)"
highlight: purple
---

Of course, it starts with a story about how I got tired of writing JavaScript, which my company uses daily. So, I decided to switch things up and migrate all the existing backend servers to Golang to keep my sanity. I moved all the code to Golang. Although it appeared to be a waste of time since we never adopted the new Go version, I learned a lot about Golang during the process. I think the best part for me was Golang's concurrency features.

That story is the reason behind article because something good came out of it. Usually, all image and asset uploads from the user are made directly via the mobile application. Since I was bored and had time to think, I decided to let the front end send the actual document to the server before uploading it to the blob store, which was Cloudinary in this case. Silly, right? Don't worry, I know 😅.

I spent 2-3 whole nights (I can't remember vividly) writing the best version of a concurrent file uploader package wrapped around the Cloudinary Go SDK, which requires more lines of code to utilize with a server. Fortunately, the next day, after I got the package to work for a few cases, I mentioned it to a lead developer, and he pointed out the flaw in my decision, but the code was over 300 lines, excluding test cases.

Like, am I going to delete it? Hell no 🫠\`.

Therefore, I abandoned the package and went back to writing JavaScript. A few months later, someone in a Nigerian gopher group asked for help with Cloudinary integration. I shared the entire code from my failed project with them. Then, I decided to extract it as a library and share it with others to help simplify their integration process.

This led me to create a library called [kloudinary](https://github.com/caleberi/kloudinary/tree/latest) that does the following :

* Simplifies file uploads to Cloudinary.
    
* Supports multiple file uploads in one go.
    
* Easily destroy assets by public ID.
    
* Transform images with minimal code.
    
* Configurable asset upload settings.
    

Kloudinary as a wrapper around the official Cloudinary SDK streamlines some redundant parts of using the official SDK and can get you started within minutes of installation.

To install it just do `go get`[`github.com/caleberi/kloudinary`](http://github.com/caleberi/kloudinary)

Then you are all set to write your main code, for example

```go
package main

import (
	"github.com/caleberi/kloudinary"
	"log"
)

func main() {
	cloudName := "your-cloud-name"
	apiKey := "your-api-key"
	apiSecret := "your-api-secret"

	am, err := kloudinary.NewAssetUploadManager(cloudName, apiKey, apiSecret)
	if err != nil {
		log.Fatalf("Failed to initialize AssetUploadManager: %v", err)
	}
    
    am.MaxAssetSize = 10 * 1024 * 1024 // 10 MB
    am.MaxUploadTimeout = 30 * time.Second
    am.MaxNumberOfConcurrentUploads = 5

    // single file upload
	result, err := am.UploadSingleFile(ctx, "path/to/your/file.jpg")
    if err != nil {
        log.Fatalf("Failed to upload file: %v", err)
    }
    log.Printf("Upload successful: %v", result)

    // multiple file upload
    results := am.UploadMultipleFiles(ctx, "path/to/file1.jpg", "path/to/file2.png")
    for _, res := range results {
        log.Printf("Upload result: %v", res)
    }
}
```

Here is an example of the internal test case upload for multiple files and videos with a max timeout of 30 seconds

```bash
=== RUN   TestLargeAssetUploadManager_UploadMultipleFiles
2024/07/18 23:47:16 error: [/Users/soundboax/Desktop/projects/golang/kloudinary/upload/.DS_Store] = invalid MIME type
2024/07/18 23:47:16 upload speed (0.00s)
2024/07/18 23:47:16 upload speed (3.92s) : ( /Users/soundboax/Desktop/projects/golang/kloudinary/upload/test0.png ) 
2024/07/18 23:47:16 Secure-url for [images/test0.png] = https://res.cloudinary.com/drc1rgo58/image/upload/v1710463887/images/test0.png.png
2024/07/18 23:47:16 upload speed (7.87s) : ( /Users/soundboax/Desktop/projects/golang/kloudinary/upload/test1.png ) 
2024/07/18 23:47:16 Secure-url for [images/test1.png] = https://res.cloudinary.com/drc1rgo58/image/upload/v1710463892/images/test1.png.png
2024/07/18 23:47:16 upload speed (6.42s) : ( /Users/soundboax/Desktop/projects/golang/kloudinary/upload/test2.png ) 
2024/07/18 23:47:16 Secure-url for [images/test2.png] = https://res.cloudinary.com/drc1rgo58/image/upload/v1710463907/images/test2.png.png
2024/07/18 23:47:16 upload speed (0.67s) : ( /Users/soundboax/Desktop/projects/golang/kloudinary/upload/test5.xml ) 
2024/07/18 23:47:16 Secure-url for [documents/test5.xml] = https://res.cloudinary.com/drc1rgo58/raw/upload/v1721294115/documents/test5.xml
2024/07/18 23:47:16 Average upload time = (3.15s) totalTime = (18.88)
--- PASS: TestLargeAssetUploadManager_UploadMultipleFiles (18.88s)
PASS
```

In short, Kloudinary makes integrating with Cloudinary very simple. It is not all done yet but it can be better.

Sorry for boring you with the initial details. I just wanted to show that initial ideas might not work, but later ones might succeed.

Feel free to try out the library and also raise issues or PR to make it better.