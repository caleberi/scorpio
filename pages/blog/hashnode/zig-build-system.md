---
title: "Building zig progam with the build system"
summary: "Using a logical cross platform dependency free approach to building zig project"
authors:
  - "Caleb Adewole"
date: "2026-09-03"
topics:
  - "Zig"
  - "build system"
  - "Learning"
  - "Source Code"
type: "Blog"
image: "![image](../../../blobs/cover58.jpeg)"
highlight: purple
---

> This article is written as a manual for a newbie in zig so you can understand with the build system does and how to quickly use it when building applications 

Zig's build system is a quite powerful way for expressing how you want your project to be built. If you have ever used systems like Cmake, Meson, or Bazel, you will find that Zig's build system is a lot simpler and easier to use. It is also cross-platform and dependency-free, which makes it a great choice for building Zig projects. Why?  because you write in zig to get everything out of the way.

In simple way, think of the system as a way of describing the steps involved in your program bit by bit. All you need to do is to remember all your files and how they are related to each other. Once that is at the back of you mind. It is all about trees. Trees ? yes, trees. The build system is a tree of dependencies nodes that you can use to describe how your program should be built. Each node in the tree represents a file or a group of files, and the edges represent the dependencies between them. The build system will then use this tree to determine the order in which to build your program.

Let start from the beginning, assume we have a simple zig project with the following structure:

```
my_project/
├── src/
│   ├── main.zig
│   └── root.zig
├── config.json
├── build.zig
└── build.zig.zon
```

And we need to compile it into an executable. The first step is to create a `build.zig` file in the root of your project. This file will contain the build instructions for your project. Here is a simple example of what the `build.zig` file might look like:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
  // Zig described compilation steps here
}
```

The `build` function is the entry point for the build system. It takes a pointer to a `std.Build` object, which provides methods for defining build steps. Inside the `build` function, you can define the steps needed to compile your project.

## Target Platform
The next step is tell the build system the machine architecture and the target platform. This is important because Zig can cross-compile to different platforms. You can specify the target platform using the `b.setTarget()` method. For example, if you want to build for Windows, you would do something like this:

```zig
const target = b.standardTargetOptions(.{}); 
```
By setting the struct option argument to this function, zig will automatically detect the host platform and set the target accordingly. You can actually write your own logic to decide how the target should be set. For example, you can use the `std.Target` struct to specify a specific target platform and architecture. 

## Optimization Plan

After setting the target platform, you can specify the optimization level for your build. Zig provides several optimization levels, ranging from no optimization to full optimization. You can set the optimization level using the `b.setOptimizationLevel()` method. For example, to set the optimization level to `ReleaseFast`, you would do something like this:

```zig
const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
```

## Optional Arguments

For times when you want to pass optional arguments to your build, you can use the `b.addOption()` method. This allows you to define custom build options that can be specified when invoking the build system. For example, you might want to add an option for enabling debug mode:

```zig
// packageVersion can be a function that returns a value
const config = b.addOptions();
config.addOption([]const u8, "manifest_url", manifest_url);
config.addOption([]const u8, "package_version", packageVersion(b));
```

## Root Module

One important thing is that to get an executable, you need to specify the root module of your project. The root module is the entry point of your program, and it is usually the `main.zig` file. And you need to define this module before tell the buill system to add it as the executable. For example , you can say I want to add a module call root_mod that points to the `main.zig` file like this:

```zig
const root_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
root_mod.addOptions("config", config);
```
Look closely at the last line, we are adding the optional arguments to the root module. This is important because it allows you to pass custom build options to your program.

## Creating the Executable

Finally, you can create the executable by calling the `b.addExecutable()` method. This method takes the name of the executable and the root module as arguments. For example, to create an executable called `my_program`, you would do something like this:

```zig
const exe = b.addExecutable(.{
    .name = "atlas-push-cli",
    .root_module = root_mod,
});
```

If you notice since the beginning we have been using the `b` object to define all the build steps. This is because the `b` object is the main interface for interacting with the build system. Therefore, we need to install the executable node into the project tree by calling the `b.installExecutable()` method. This method takes the executable node as an argument and adds it to the project tree. Like this:

```zig
b.installArtifact(exe);
```
One wonderful thing about the build system is that it automatically handles dependencies between files. For example, if you have a file called `root.zig` that is imported by `main.zig`, the build system will automatically detect this dependency and ensure that `root.zig` is compiled before `main.zig`. This means that you don't have to worry about manually specifying the order of compilation for your files.

Another thing is the ability to install files alongside the executable. This is useful for cases where you have configuration files or other resources that need to be included with your program. You can use the `b.installFile()` method to specify files that should be installed alongside the executable. For example, if you have a configuration file called `config.json`, you would do something like this:

```zig
b.installFile(b.path("config.json"), b.path("config.json"));
```

## Adding Tests

You may also want to add tests to your project. This is a easy as creating an test node and adding it to the project tree. You can use the `b.addTest()` method to create a test node, and then use the `b.installTest()` method to add it to the project tree. For example, if you have a test file called `test.zig`, you would do something like this:

```zig
const unit_tests = b.addTest(.{
      .root_module = b.createModule(.{
          .root_source_file = b.path("src/main.zig"),
          .target = target,
          .optimize = optimize,
      }),
  });

const run_unit_tests = b.addRunArtifact(unit_tests);
const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_unit_tests.step);
```

With all these steps in place, you can now build your project by running the following command in your terminal:

```bash
zig build
```

GBAM!!! 🙌 , Now you understand how to use the build system to build your zig project. Just like that 🎉 🚀.


If you want to learn more about the build system, you can check out the official documentation [here](https://ziglang.org/documentation/master/#Build-System). It provides a comprehensive guide to all the features and capabilities of the build system.




