---
title: "Exploring Zig: My Experience and Insights"
summary: "Three Months of Zig Programming: My Insights and Experience"
authors:
  - "Caleb Adewole"
date: "2026-08-19"
topics:
  - "Zig"
  - "Experience"
  - "Learning"
type: "Blog"
image: "![image](../../../blobs/cover15.jpeg)"
highlight: lime
---

It has been a while since I have written anything, I still have some pending articles to complete in golang but for the fun of it, let me tell you what I have been up to lately.

I piqued an interest in Zig about two months ago since I have been interested in system programming a lot since my second year in school which is why I learnt C/C++ but since my location requires more of being an embedded engineer to use both languages, I did not use it for much. I built an email sender and garbage collector in C and C++ respectively. Now, after seeing Primeagen's video on [tigerbeetle](https://tigerbeetle.com) which is a distributed financial accounting database, I decided to check it out.

Fortunately for me, I saw this line below and was excited to use my knowledge from C and Go together in a single place with a few features from rust.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1726502068501/51d1fec1-2c56-48f9-8136-679d252b5f56.png align="center")

One thing I don’t like is using a language because some said so, I have to do my findings before writing programs in the language.  
I, therefore, went through the documentation and these few things impacted my learning more

* Memory allocation and use of defer to handle RAII
    
* Build system: Easy to build C and C++ libraries which means support for legacy code without having to learn CMake. I love this
    
* Variety of memory allocators to select from depending on the use case
    
* The Zig Discord channel seems helpful to me.
    
* Speed is also one factor too.
    
* Compile time evaluation - eg code unrolling
    
* Optional values and error handling
    
* I can port to building games and other interesting things with less difficulty.
    

Those are just some of the reasons for learning Zig since it is just starting to gain traction.

Anyway, with that being said, I think for most people who are not familiar with memory management it might be a little hard to understand.

Here are the things that might be a bit difficult :

* Understanding the standard library - (I find it easy when I read the standard library source code and play around with things)
    
* Meta-programming
    
* Compile time programming
    
* Interoperating with C and C++
    

I think that is all I can remember for now. I am just 3 months old in the language and my opinion is subject to change but I think it is worth taking a look into.

You can join the Zig community here : [https://github.com/ziglang/zig/wiki/Community](https://github.com/ziglang/zig/wiki/Community)
