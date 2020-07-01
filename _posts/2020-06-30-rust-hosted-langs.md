---
layout: post
title:  "Languages Hosted in Rust: an online book"
date:   2020-06-30 12:22 EST5EDT
categories: rust-hosted-langs
comments: false
---

# An online book, "Writing Interpreters in Rust: a Guide"

A couple of years ago I wrote
[a proposal on IRLO](https://internals.rust-lang.org/t/anybody-interested-in-a-languages-hosted-in-rust-wg/7243)
to start a working group for programming languages written in Rust.

An [organization](https://github.com/rust-hosted-langs) was started on Github
and some skeleton repositories created. A few folk pitched in with some early
discussion in Gitter and Github issues.

We didn't have a coherent direction though until Yorick Peterse suggested
writing a book on the topic of writing an interpreter in Rust. That set the
direction I would take.

However,

1. There was no suitable existing source code to base a book on
2. I had never written an interpreter myself and so had to learn from scratch
   (yes I know, cart before horse!)
3. Bootstrapping this effort as a _community_ seemed like it wouldn't be
   successful until 1 and 2 were solved

I began the journey of both writing an interpreter I see as suitable for a
book and learning how that should work in Rust _and_ doing it alone in a spare
early morning hour a few times a week. So we'd have something to work from.

Now, I'd like to make public what I have so far, which is, in short:

* an allocator
* an s-expression language compiler and interpreter that support expressions,
  functions and closures
* a few chapters of the book written

There's much more to do and contributions are invited and welcomed!


## Philosophy of the project

My hope is that this book and source code empowers _you_ to create new
languages in Rust. I want to do my part to make the software landscape
a better place. If we all write more software in languages that prevent
memory safety bugs, we'll be gifting future generations a safer connected
world.

With that in mind, the source code here is dual Apache/MIT licensed for the
broadest compatibility with the Rust ecosystem and to encourage you to
fork the code and turn it into your own creation. A language creation kit of
sorts.

The code architecture philosophy should follow modularity. If I want you
to take and modify this code, it follows that it should be relatively easy
to swap one components implementation out for another. The existing code can
be improved in this direction.


## What now? Where? And what is there to do?

The repo can be found at <https://github.com/rust-hosted-langs/book/>. There
are subdirectories:

* `booksrc`: this is the markdown for the book chapters
* `blockalloc`: a crate containing a blocks-of-memory allocator
* `stickyimmix`: an allocator and garbage collector
  Right now the allocator is implemented but mark & sweep remains to be done.
* `interpreter`: an s-expression based language compiler, a bytecode virtual
  machine and all the supporting data structures and types


### Sticky Immix allocator

The architecture for this code is best understood by reading the book chapters
on the topic.


### The interpreter

After the allocator chapters and code are understood, the first interpreter
chapters serve as a guide to how the interpreter interfaces with the
allocator. I recommend reading these available chapters first.


### Specific areas of improvement

The book needs to be written. I plan to work on this until the book reaches
parity with the source code.

There is plenty to improve in the source code:

* I stopped keeping up-to-date with idiomatic Rust, language features and
  standard libarary stabilzations so I could focus on getting code written.
* Some of the code was written to just get something working and is probably
  quite ugly!
* There are many opportunites for optimizations, even while bearing in mind
  that this is book and code should optimize for readability and extensibility
  first.
* There are probably some soundness and unsafety leaks. I spent a long time
  thinking this all through but the more eyes on it the better!
* A basic mark & sweep garbage collector needs to be implemented.
* Because it was the easiest way for me to bootstrap into parsing and
  compiling, these components are based on creating and parsing a cons-cell
  data structure. This could be rethought because who _really_ cares about
  cons cells!
* The interpreter could be split up into sub-crates to improve modularity.

The source code has numerous TODOs around it. Some of these are features that
need implementing and some are refactorings.  The are compiler warnings,
mostly for never-called functions (usually this also implies a TODO.)

The book itself has not been fully proof read and edited.


## Structure and organization of Languages Hosted in Rust

This is a Github organization with a few other repositories.
General organizational queries and issues should be posted to the
<https://github.com/rust-hosted-langs/runtimes-WG> repository.

I created a Gitter channel for discussions but the chat sands have shifted
various ways in the intervening years and I'm open to bikeshedding
alternatives. Gitter attendance has dwindled to just myself anyway!

## Contributions welcome!

If this project is for you, feel free to

* drop in on [Gitter](https://gitter.im/rust-hosted-langs/runtimes-WG)!
* ask questions!
* read the book and source to get oriented
* open issues or PRs on <https://github.com/rust-hosted-langs/book>
