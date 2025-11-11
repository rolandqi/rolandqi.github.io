---
title: >-
  Will Multiple Link Libraries with Same Function Names Cause Compilation Errors
  in CC++
date: 2022-11-11 12:09:11
tags:
- C++
- GCC
- Linking
---

## Background

Due to business requirements, our company uses a closed-source C++ program from Mellanox. Mellanox's recommended customization approach is to perform custom development on the dynamically linked libraries to add additional functionality.

During the solution discussion phase, I found that many colleagues were not very clear about the meanings represented by dynamic/static libraries, ‌especially when same-name functions exist‌. There was also no clear understanding of what the compilation, linking, and runtime results would be, hence this article was written.

## Basic Concepts

Program function libraries can be divided into the following types:

‌1. **Static libraries**‌: During compile-time, static libraries are entirely copied into the compilation target, typically existing as .a files
‌2. **Shared libraries‌**: Loaded into the program when it starts, they can be shared by different programs, typically existing as `.so` files
‌Dynamically loaded libraries‌: During process runtime, use functions from dlfcn.h to load, call, and close dynamic libraries

##Testing Same-name Functions

Using two `.c` files `test1.c` and `test2.c` containing the same-name function void test()

```c++
// test1.c
#include <stdio.h>

void test() {
    printf("call from test1.c");
}
```

```c++
// test2.c
#include <stdio.h>

void test() {
    printf("call from test2.c");
}
```

File containing the main function main.c

```c++
// main.c
extern void test();
int main() {
    test();
}
```

### Test 1: `.o` Object Files

Using the following command line, generate object files from test1.c and test2.c, and compile the executable:

```c++
gcc -c ./test1.c
gcc -c ./test2.c
gcc -o main ./test1.o ./test2.o ./main.c
```

Resulting in error:

```txt
./test2.o: In function `test':
test2.c:(.text+0x0): multiple definition of `test'
./test1.o:test1.c:(.text+0x0): first defined here
collect2: error: ld returned 1 exit status
```

As we can see, linking object files containing same-name functions in the same namespace will result in a multiple definition error.

### Test 2: Static Libraries

Using the following command line to compile static libraries libtest1.a and libtest2.a:

```bash
g++ -c ./test1.c
g++ -c ./test2.c
ar crv libtest1.a test1.o
ar crv libtest2.a test2.o
```

Then we link and compile:

```bash
gcc -L. ./main.c -ltest1 -ltest2 -o main
```

Compilation succeeds without errors. Execution result:

```bash
$ LD_LIBRARY_PATH=. ./main
call from test1.c
```

Some might ask: "Why no error? I clearly linked two static libraries containing same-name functions into the same executable."

To investigate why no error occurred, let's add the ld option `-Wl,--verbose` to see what exactly happens during linking. Re-executing compilation, we get the output:

```txt
...

attempt to open ./libtest1.so failed
attempt to open ./libtest1.a succeeded
(./libtest1.a)test1.o
attempt to open ./libtest2.so failed
attempt to open ./libtest2.a succeeded

...
```
We can discover that in the final linking result, the output binary only linked the `test1.o` file from `libtest1.a`, but did not link `libtest2.a`. The compiler's behavior means:

1. The compiler searches link libraries sequentially according to linking order.
2. First, it finds `libtest1.a` and discovers it has the function void test() needed by the main function, so it links it.
3. When scanning to `libtest2.a`, since `void test()` is already provided by the symbol from `libtest1.a`, it's no longer linked.
A question on [Stack Overflow](https://stackoverflow.com/questions/55130965/when-and-why-would-the-c-linker-exclude-unused-symbols) also discusses this point.

If we use the ld parameter `--whole-archive` to forcibly link `libtest1.a` and `libtest2.a`, we'll see the same error as in Test 1:

```txt
$ gcc -L. ./main.c -Wl,--whole-archive -ltest1 -ltest2 -Wl,--no-whole-archive -o main
./libtest2.a(test2.o): In function `test':
test2.c:(.text+0x0): multiple definition of `test'
./libtest1.a(test1.o):test1.c:(.text+0x0): first defined here
collect2: error: ld returned 1 exit status
```

### Test 3: Dynamic Libraries

Using the following command line to compile dynamic libraries `libtest1.so` and `libtest2.so` and compile the executable:

```bash
gcc -shared -fPIC -o libtest1.so test1.c
gcc -shared -fPIC -o libtest2.so test2.c
gcc -L. ./main.c -ltest1 -ltest2 -o main
```

Compilation succeeds without errors. Checking with ldd confirms that both libtest1.so and libtest2.so are indeed linked into the main executable. Execution result:

```bash
$ LD_LIBRARY_PATH=. ./main
call from test1.c
```

This shows that during dynamic linking, different link libraries can have same-name functions without affecting compilation. This is determined by the nature of dynamic link libraries, which are only dynamically loaded at runtime, and the loading order is determined by the linking order during compilation. This means symbols are resolved on a first match basis.

We can also use `LD_PRELOAD` to [preload](https://stackoverflow.com/questions/426230/what-is-the-ld-preload-trick) a certain dynamic library into memory.

## Applications of Same-name Functions

Some might question: Can it be used in daily work? The answer is definitely yes.

The simplest application scenario: for example, if there's a function in an open-source library that I don't like, and I want to write my own version to replace it, I can completely use the above knowledge to link my implemented function into the executable file dynamically or statically, replacing the version I don't like.

Common industrial applications include:

‌1. Library Replacement‌: The famous `tcmalloc` operates in this way. We link tcmalloc into the program, and as long as the tcmalloc library's search order precedes libc, we can replace the native memory management functions with the tcmalloc version.
‌2. Mock Testing‌: Chen Shuo detailed in an article how to mock system calls in C++ unit testing. The ‌**link seams‌** method utilizes the characteristic that libc is generally dynamically linked to mock system calls in the process.
