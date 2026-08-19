---
title: 'Why manifest file can be a secret power'
summary: 'Thoughts on why manifest should be considered when building some system'
authors:
  - 'Adewole Caleb'
date: '2026-08-17'
topics:
  - 'Caching'
  - 'Engineering'
  - 'Servers'
  - 'Disk'
type: 'Blog'
image: '![image](../../../blobs/cover9.webp)'
---

Manifest files, bunch of files storing metadata information about a system probably needed at boot time or runtime. In most systems, the files can be a json, xml, text or any type of file that stores metadata information. Metadata is just a fancy word to describe data that describes other data. So not too much gymanists there.

In the project powering this blog, we have a manifest file that stores metadata information about the blog. The manifest file is a json file that stores the following information:

- slug: the slug of the blog post
- path: the on disk path to the blog post
- chunk: the chunk of that storing post information
- offset: the offset of the blog post i.e [start_index, end_index]
- length: the length of the post
- modified_at: the modified time of the blog post
- sha256: the sha256 hash of the blog post

I figure that storing this information in a manifest file is a good idea because it allows us to quickly and easily access the blog post information without having to read the blog post from the disk. Essentially, it is more an efficient to cache all the available post information.

Key decisions in creating a manifest file is to first consider that data to be stored then finding an exist syntax eg json, xml, text or any type of file that stores metadata information. Once this is done the next step is to consider the file structure and how to store & load the data.

For example, I had to decide a few thinks while creating a manifest. They were:

1. Since, I am storing chunk information so I have a clear direction on the size, the file and also if the content of the file changed, The chunk entry, as well as the hash became a valid decision.
Therefore storing some like this  is good :
```json
{
  "chunk": {
    "size": 1024,
    "file": "blog_posts.txt",
    "hash": "1234567890"
  }
}
```

2. One funny thing about chunks is that can be splitted accross multiple files. Therefore, I had to decide on a way to store the information about the files that make up the chunk. This is where the document entry comes in.
```json
{
  "document": {
    "slug": "blog-post-1",
    "path": "blog_posts/blog_post_1.txt",
    "chunk": 1,
    "offset": [0, 1023],
    "length": 1024
  }
}
```

3. Once all information about the important data is known, A general wrapping structure can be provided to store and track it generation.
```json
{
  "version": 1,
  "generated_at": "2026-08-17T12:00:00Z",
  "chunk_size": 1024,
  "chunks": [
    {
      "size": 1024,
      "file": "blog_posts.txt",
      "hash": "1234567890"
    }
  ],
  "documents": [
    {
      "slug": "blog-post-1",
      "path": "blog_posts/blog_post_1.txt",
      "chunk": 1,
      "offset": [0, 1023],
      "length": 1024
    }
  ]
}
```

4. Final step is to use your language of choice to load the data into your system. In my case, I am using Zig and the `std.json` module to load the data.
```zig
const std = @import("std");
const json = std.json;

const manifest = json.parseFromSlice(Manifest, data, .{});
```

5. Once the data is loaded, you can use the data to access the blog post information without having to read the blog post from the disk.

### What does this do for us? 
In my own particular case, I have a blog post that is 1024 bytes long. I can store the information about the blog post in a manifest file and then use the manifest file to access the blog post information without having to read the blog post from the disk. In this case disk might be a blob storage eg s3, cloudinary or any other storage system. I will argue that one can use a CDN provider also to ones advantage for delivery instead of a round trip round the world.


> Manifest files is just another variation of a cache file.

Sign out!
Peace.🫠