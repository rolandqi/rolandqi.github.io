---
title: How to Manage Memory Alignment in Modern C++
date: 2022-09-25 10:21:28
tags:
- C++
- Memory
---

## Why Need Memory Alignment

1. Nowadays computer processor does not read from and write to memory in byte-sized chunks. Instead, it accesses memory in two-, four-, eight- 16- or even 32-byte chunks **granularity**. So accessing unaligned memory would give us great overhead.
2. All modern processors offer atomic instructions. These special instructions are crucial for synchronizing two or more concurrent tasks. For atomic instructions to perform correctly, the addresses you pass them must be **at least four-byte aligned**(to avoid memory access across pages). Otherwise, it would cause failure, or worse, silent corruption.
3. **Some instructions**(like some AVX-512 instructions) are designed to have memory alignment requirements, for speed concerns.
4. modern compilers sometimes automatically padded the *structure* for backward compatibility and efficiency concerns.
5. **cache line**: alignment of data may determine whether an operation touches one or two cache lines. Reducing *false sharing* problem.

## C++ in Practice

In most of the cases, C++ itself has already dealt with the memory alignment automatically. But sometimes we need better control of the memory arrangement to achieve better performance. Moreover, as any overzealous C++ programmer would do. We want to understand anything behind the programming language so we can abuse it.

### specify alignment requirement for structure(on the stack)

An object, in C, is region of data storage in the execution environment. So every object has **size**(can be determined with `sizeof`) and **alignment requirement** (can be determined by `alignof`(since C11)) attributes. Each basic type has a default alignment, meaning that it will unless otherwise requested by the programmer, be aligned on a pre-determined boundary. The only notable differences in alignment for an LP64 64-bit system when compared to a 32-bit system are:

|type|32-bit|64-bit
|---|---|---|
|long|4-byte|8-byte|
|double|8-byte aligned on Windows and 4-byte aligned on Linux (8-byte with -malign-double compile time option)|8-byte|
|long long|4-byte|8-byte|
|long double|8-byte aligned with Visual C++, and 4-byte aligned with GCC|8-byte aligned with Visual C++ and 16-byte aligned with GCC|
|pointer|4-byte|8-byte|

Although the compiler normally allocates individual data items on aligned boundaries, data structures often have members with different alignment requirements. To maintain proper alignment the translator normally inserts **additional unnamed data members** so that each member is properly aligned. In addition, the data structure as a whole may be padded with a final unnamed member. This allows each member of an array of structures to be properly aligned.

**Padding is only inserted when a structure member is followed by a member with a larger alignment requirement or at the end of the structure.** By changing the ordering of members in a structure, it is possible to change the amount of padding required to maintain alignment. For example, if members are sorted by descending alignment requirements a minimal amount of padding is required. The minimal amount of padding required is always less than the largest alignment in the structure. Computing the maximum amount of padding required is more complicated, but is always less than the sum of the alignment requirements for all members minus twice the sum of the alignment requirements for the least aligned half of the structure members.

For example, here is a structure with members of various types, totaling **8 bytes** before compilation:

```c++
struct MixedData
{
    char Data1;
    short Data2;
    int Data3;
    char Data4;
};
```

After compilation the data structure will be supplemented with padding bytes to ensure a proper alignment for each of its members:

```c++
struct MixedData  /* After compilation in 64-bit x86 machine */
{
    char Data1; /* 1 byte */
    char Padding1[1]; /* 1 byte for the following 'short' to be aligned on a 2 byte boundary
assuming that the address where structure begins is an even number */
    short Data2; /* 2 bytes */
    int Data3;  /* 4 bytes - largest structure member */
    char Data4; /* 1 byte */
    char Padding2[3]; /* 3 bytes to make total size of the structure 12 bytes */
};
```

Also, we could use `pragma pack(n)` to specify the packing alignment for structure, union, and class members. `n` becomes the new packing alignment value. Moreover, we could also use `#pragma pack(1)` to not align anything.

#### `alignas`

since c++11, we could use `alignas` to Specify the alignment requirement of **a** type or an object. If multiple `alignas` are met, the strictest(largest) alignment would be chosen.

```c++
struct alignas(16) Bar
{
     int i;  // 4 bytes;
     int n;  // 4 bytes;
     alignas(4) char arr[3];
     short s;  // 2 types
};

int main()
{
    std::cout << alignof(Bar) << std::endl;  // output 16
}
```

### memory alignment for heap memory allocation

The address of a block returned by `malloc` or `realloc` in GNU systems is always a multiple of eight (or **16 on 64-bit systems**). If we need a block whose address is a multiple of a higher power of two than that, use `aligned_alloc` or `posix_memalign`. (`aligned_alloc` and `posix_memalign` are declared in `stdlib.h`)

if you use a gcc/clang compiler supporting C++17 and above, you can use `aligned_alloc` to get spcific alignment.

```c++
void *aligned_alloc( size_t alignment, size_t size );
```

And **C++17** also have a new feature called **aligned new** to support allocation alignment:

```c++
void* operator new  ( std::size_t count, std::align_val_t al );
```

Moreover, in **C++17**(GCC>=7, clang>5, MSVC>=19.12) the standard allocators have been updated to respect type's alignment, so containers can allocate appropriate memory meets memory alignment requirement.

```c++
class alignas(32) Vec3d {
    double x, y, z;
};

class foo {
    int x;
};

int main() {
    std::cout << sizeof(Vec3d) << std::endl;  //  output 32
    std::cout << alignof(Vec3d) << std::endl;  //  output 32
    
    // specify align_val_t, but need manually call destructor.
    auto p_aligned_type = new (std::align_val_t{32}) foo;
    p_aligned_type->~foo();
    ::operator delete(p_aligned_type, std::align_val_t{32});

    // using container to allocate aligned memory.
    std::vector<__m256> vec(10);
    vec.push_back(_mm256_set_ps(0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f));
    asssert(reinterpret_cast<uintptr_t>(vec.data()) % alignof(__m256) == 0);
};
```

### Preferences

1. [Data structure alignment](https://en.wikipedia.org/wiki/Data_structure_alignment)
2. [Purpose of memory alignment](https://stackoverflow.com/questions/381244/purpose-of-memory-alignment)
3. [Data alignment: Straighten up and fly right](https://developer.ibm.com/articles/pa-dalign/)
4. [Gallery of Processor Cache Effects](http://igoro.com/archive/gallery-of-processor-cache-effects/)
5. [Alignment](https://learn.microsoft.com/en-us/cpp/cpp/alignment-cpp-declarations?view=msvc-170&viewFallbackFrom=vs-2019)
6. [Allocating Aligned Memory Blocks](https://www.gnu.org/software/libc/manual/html_node/Aligned-Memory-Blocks.html)
