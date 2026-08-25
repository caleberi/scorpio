---
title: "Internship Tale at Nomba"
summary: "My experience and insights from my internship at Nomba"
authors:
  - "Caleb Adewole"
date: "2026-08-19"
topics:
  - "Nomba"
  - "Internship"
  - "Experience"
type: "Story"
image: "![image](../../../blobs/cover38.gif)"
highlight: yellow
---
Well, here I am again, in a different headspace, stuck on a bus 🤔. Let's take a trip down memory lane and see how, with effort and curiosity, Nomba's QR payment solution turned out.

## The Phone Interview 📞

One can choose how to react to situations, well, in this case, this was me sending out internship emails to companies in Nigeria, although this was not my first internship but rather my third and probably my most significant one that changed my perspective about engineering in general.

It was after COVID, following my layoff at the start of the pandemic. I often accompanied my dad to his office at the hospital, engaging in casual conversations with practising medical doctors. During this time, I reached out to a senior ([Oluwadamilola](https://www.linkedin.com/in/oluwadamilola-babalola/)) I had met on campus. I had started programming in secondary school, though I didn't fully understand what I was doing 🤣. Oluwadamilola had previously worked on the company's team before I reached my fourth year, so he gave me the email address of the company's co-founder.

I sent my internship letter well ahead of time while still interning for a company in the US without pay 😕.

No reply...

Around March, well before the internship period, I received a call from a foreign number. I had to stay calm and respectfully ask for the caller's name. In Nigeria, you have to be cautious because fraud cases are common 🤔.

The caller asked the usual formal questions and then brought up hashmaps. At this point, opportunity met preparedness. I had written my hashmap in C. I had also gone through several online assessments with Google, Stripe, Twitter, and others, so getting a question like "Tell me all about hashmaps" got me excited.

I gave a detailed answer to his question. He then asked when I was looking to start my internship. I replied, "In June." He told me to reach out when the time came.

He ended the call. I went back to what I always do (programming).

## The wait 🫸

A few months before the internship started, I began sending cold emails 😅. I think I sent about 11 emails with different paraphrased titles. The co-founder later mentioned that this persistence caught his attention and even joked about it. Eventually, I got a response, and he informed me that there would be another interview, which I wasn't expecting.

## The Main Interview 🖥️

Usually, startups in Nigeria at that time didn't hire interns from outside their location, let alone interview them. So, in this case, there wasn't much more to practice. I just went through AlgoExpert and SystemExpert tutorials. I still remember the pain of buying the course back then 😄. It was the most expensive course I had purchased.

The interview day arrived. On the call was the DevOps team lead, who asked several questions. The most important one was about preventing double-spending during payment. I answered as best as I could at the time and even sent in another solution after the call.

A little while later, I received an offer letter for an internship 🚀🚀. Don't overthink it 😂.

## The Core Engineering Team 🤯

I joined the team with experience in Node.js, although I also knew C and C++ quite well (I lost a lot of hair learning those two 😂). Anyway, the tech lead manager asked, "Do you know Java?" I was like 😲. I had picked up Java in high school, but the `System.out.println` font made me quit because I couldn't get it to write in the console. I had written `System.out.printin` instead, and there was no one to correct me back then. As a result, I disliked Java a lot. But since I was curious, I told the tech lead I would learn it within a couple of weeks.

I spent approximately 14 days and nights to understand Java to the point I could put something together. Meanwhile, I was having a session with the senior engineers namely [Tochukwu Nkemdilim](https://www.linkedin.com/in/toksdotdev/) and [Oyeyemi Clement](https://www.linkedin.com/in/oyeyemi-clement-307885aa/) trying to understand how core services worked.

After two weeks, I had played around with most Java constructs at least for an intermediate engineer to the best of my knowledge. I was tasked to build a [command line transaction dispatcher](https://github.com/caleberi/transaction-mini-dispatcher) to show how much Java I had learnt.

I can't remember his exact reply, but I think it was something like, "You are ready to take on some tasks."

## Tasks: A few that I can recall

The company had POS, mobile, and web applications, and messaging was crucial. My first assignment was working on a message resolution feature to inform users about their transactions better. This task was meant to get me started and spark my interest.

I made several mistakes and broke some code, which led to my first refactor session with Toks. He said, "Extreme ownership is important," so I had to step up, start asking questions, and read source code to improve my debugging skills.

Then, I was assigned to fix bugs in other codebases written in Python and JavaScript. I located and successfully fixed all the bugs. After this, I started to get more comfortable, so I was asked to create jobs for internal tooling notifications on Slack.

All tasks were completed. Then the big one came 😱.

My rusty Java skills were to be used to create a peer-to-peer transaction feature for crediting and debiting funds, replacing the old method of processing such transactions. While I knew how it should work, I didn't know how to write the code myself. Instead of calling the seniors, I copied and pasted code from the organization's codebase and refactored it to fit the problem statement.

The question I asked myself was, "Does this look like the right thing to do?" after asserting that it was the right thing then I pushed it for review after testing. To my surprise, the reviewer said the PR was alright but there was still much work to be done since there was a new way to implement with. Two engineers discussed the best method and I was told to work with that.

To make a long story short, I completed the task, and funds flowed smoothly from one wallet to another.

Anyway, I had to return to school since the internship ended in December.

Wait! But why is QR payment the title right? I will get to that in a bit. Just relax.

Anyway, I said my goodbyes to the team and left.

## The Strike

While strikes are uncommon in other parts of the world, they are quite normal in Nigeria, often due to pay issues. Although it shouldn't be this way, as Nigerians, we have come to accept it, hoping for a miraculous change someday. It only takes one person to start.

When I returned to school in January, there was a strike. I contacted my team's project manager to see if I could come back for another internship until the strike ended, which lasted 8 months. The team agreed and I got back to work.

## The Second One

When I rejoined the team, the previous tech lead manager had resigned, and a new one had started. I checked him out on LinkedIn and knew I had to learn as much as possible from him. My usual tasks included implementing data storage for vendor services, maintaining the codebase in Java, JavaScript, and Python, processing over 1,000 transactions, handling settlement processing of funds, improving fraud checks, and fixing major receipt bugs that prevented a new service launch. It was a lot of stress, but I loved doing it, even though it probably affected my back.

Anyway, during this time, a new engineer left the company after just two months. If I remember correctly, all the senior engineers were busy with other tasks. So, the project manager sent me a user story and asked if I could complete it within a month.

A month?? In my mind, I thought, how is that possible? A full-blown service, not just for one person but for as many devices as possible.

Anyway, it was a challenge that needed to be overcome, so I said yes, I could do it.

She informed the tech lead manager.

## The QR Service

If you've made it this far, I'm proud of you. This is the reason you've stayed with the story.

I spoke with the tech lead, and he asked me to review the necessary documents and create a system design that could work. For confidentiality, I signed an NDA. I will share a possible variant.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1720652087805/055f7f44-8e6c-41a1-8e18-aeb793d4f9d4.png align="center")

I created a design that could work for all types of supported devices: POS, phones, printable formats, and web. After the design was done, we had a series of iterations making the design better and pluggable into the ecosystem. After the lead was satisfied with the design, he said to map out how long it would take to implement it. He included an extra 2 weeks' extension.

## Implementation

Well since the core team uses Java, that was the defacto language to use even though I suggested using golang I didn't win the argument. I had to use Bazel.

And here is why I don't like build-tool. It's like another tutorial on its own. I just want to write the code and test it. Anyway, I had to use it in a mono-repo so it was difficult figuring out compilation steps and dependency addition.

A major focus was on implementing a GRPC (Google Remote Procedure Call) server to handle all QR payment requests. I had to set up the database and then implement the methods needed to determine which users required the QR service for their businesses. The method is exposed to the service that needs to be used.

How long do you think this took? One month?

Nah, it took 4 months. It's not about how fast you do it, but how well you do it.

Interestingly, it worked when I moved on to another company. The next time I saw this in action was while watching a match outdoors on DSTV and [YouTube](https://www.youtube.com/watch?v=639XS1IbFwQ). You can imagine the rest.

## Summary

You may think the story wasn't technical enough. It wasn't meant to be. The point is that it's okay not to know everything. The goal is to figure things out along the way. Ask for help when needed, stay curious, and enjoy the journey.
