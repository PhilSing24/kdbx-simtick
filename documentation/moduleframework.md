# Modules

## Modules Overview

This page explains what modules are, why they matter, and introduces the available modules.

What are modules
Modules are a unit of encapsulation in KDB-X. They have access to their own local namespace that can contain internal and external functions and variables for the module, as opposed to designating a fixed global namespace as it is often done for pre-module libraries.

The modules can expose variables and functions using the export variable, which can then be imported by code with the use function and assigned to an arbitrary name. Modules can be written in q or using the C API.

Use the module framework to build, import, and manage modules in KDB-X.

Official KX modules
Below is a list of official KX modules shipped with KDB-X.

| Name | Description | Owner | Latest Version |
|------|-------------|-------|----------------|
| Parquet | A columnar storage format optimized for efficient querying and analytics on large datasets. | KX | 1.0.0 |
| AI Libraries | AI module for summarizing information, assisting users, and solving complex problems across various industries. | KX | 1.0.0 |
| Object Storage | Enables scalable queries through seamless cloud object storage access. | KX | 1.0.0 |
| SQL | Enables SQL querying capabilities within KDB-X. | KX | 1.0.0 |
| Kurl | Provides a simple way to interact with KDB-X using REST APIs. | KX | 1.0.0 |
| Rest Server | Exposes KDB-X functionality over a RESTful API. | KX | 1.0.0 |

Open source modules
Below is a list of open source modules shipped with KDB-X.

| Name | Description | Owner | Latest Version |
|------|-------------|-------|----------------|
| BLAS | Basic Linear Algebra Subprograms, low-level routines for performing common linear algebra operations. | OS | 1.0.0 |
| Regex - PCRE2 | Used to match, search, and manipulate text patterns using rule-based expressions. | OS | 1.0.0 |
| Logging | Provides logging capabilities for KDB-X applications. | OS | 1.0.0 |
| Printf | Replicates a subset of the C99 printf standard to format strings. | OS | 1.0.0 |
| Fusionx | Simplifies the use of native libraries within a q environment. | OS | 1.0.0 |


## Module Framework

### Module Management
This page introduces the module framework in KDB-X and explains what modules are and why they matter.

#### Module framework
The module framework is the foundation for extensibility in KDB-X. It gives you a consistent way to build, import, and manage modules in both KDB-X and the q language.

Its purpose is to make the platform easier to extend and adapt, whether you're scaling to bigger data, pulling in new types of datasets, or experimenting with new workflows.

#### What it does
The module framework enables you to:

Build and import modules easily. You can write your own functionality in q, package it up as a module, and load it into KDB-X.

Tap into a shared ecosystem. Many modules are open source, and KX is creating a central place for developers to share and reuse them.

#### What are modules
Modules are a unit of encapsulation in KDB-X. They have access to their own local namespace that can contain internal and external functions and variables for the module, as opposed to designating a fixed global namespace as it is often done for pre-module libraries.

The module can expose variables and functions using the export variable, which can then be imported by code with the use function and assigned to an arbitrary name. Modules can be written in q or using the C API.

Module properties
A module shows the following properties:

It is isolated:
  in-memory: A module should only write to its own private namespace.
  on-disk: Everything required to load the module fits into one file or directory.

It is portable:
  in-memory: Its source code should be free of absolute path literals like .a.b:.c.d. Module-relative namespace paths are used within a module. However, if necessary, computed absolute paths provided by other modules can be used.

  on-disk: The module's fully qualified name is derived from its file/directory path. Renaming or moving the module should not change this behavior unless the module depends on a parent.


## Get Started with the Module Framework

### Create modules
The minimum requirement you need for creating a module is defining a variable named export containing a dictionary of the public interface of the module. For example:

export:([f:{x+1};g:{x*2}])

This creates a module with two functions, f and g.

To load the module, place it on the search path using an appropriate file name - as described in the search path section below - then load it via the use function:

// $QHOME/mod/foo/init.q
export:([f:{x+1};g:{x*2}])

// user
q)foo:use`foo
q)foo.f 10
11
q)foo.g 10
20

The use function returns the module's export, allowing it to be stored in a variable in the user code.

### The export variable

The basic export variable is a dictionary:

export:([f:{x+1};g:{x*2}])

The definitions do not have to be inline - bracketed dictionary syntax allows for deriving the keys from the variable names:

f:{x+1}
g:{x*2}
export:([f;g])

In binary modules, the equivalent is to export a function named kexport (the name is not export because that is a reserved word in C++) which constructs the dictionary, using dl to create the objects representing the module functions:

K kexport(K x) {
    K names = ktn(KS,2);
    kS(names)[0] = ss("foo");
    kS(names)[1] = ss("bar");
    K fns = ktn(0,2);
    kK(fns)[0] = dl((void*)k_foo, 1);
    kK(fns)[1] = dl((void*)k_bar, 1);
    return xD(names, fns);
}

### Local namespace

// library
.foo.f:{x+1}
.foo.g:{x*2}

// user
.foo.f[3]+.foo.g[4]

// library
\d .foo
f:{x+1}
g:{x*2}

// user
.foo.f[3]+.foo.g[4]


This is problematic because if two libraries decide to use the same namespace name, they will clash, which incentivizes the usage of long and/or nested namespace names to ensure unicity. Furthermore, the internal variables and functions of libraries are exposed to the user, breaking encapsulation.

In contrast, modules should not use absolute names for either variables or namespaces. During the loading of a module, its current namespace is switched to a module-specific namespace that it can use to store internal variables and functions:

MULT:2 // private value
f:{x+1} // private function
g:{f[x]*MULT}
export:([g])

The idea behind encapsulation is that users of the module should not directly access or modify the internal functions and variables. Variables cannot be made public (if added to export, the user gets a copy, not a reference) - to allow accessing them, the module should provide getter/setter functions.

// $QHOME/mod/foo/init.q
MULT:2 // private value
f:{x+1} // private function
g:{f[x]*MULT}
getMult:{MULT}
setMult:{MULT::x}
export:([g;getMult;setMult])

// user
q)foo:use`foo
q)foo.getMult[]
2
q)foo.g[10]
22
q)foo.setMult 5
q)foo.g[10]
55

### Self-reference

Sometimes it is necessary to refer to the namespace the module is defined in. This can be achieved using the built-in variables .z.m and .z.M.

.z.m refers to the namespace of the current module
.z.M is a symbol containing the name of the namespace
Furthermore, any name can be added to .z.M as if it was a member of that namespace to generate a symbolic name under the module namespace. When used in functions, .z.m and .z.M retain the information about which module they were defined in, as opposed to changing the reference based on what the current module is.

// $QHOME/mod/foo/init.q
// log:{-1 string[.z.P]," ",x}  // doesn't work, since log is a reserved name
.z.m.log:{-1 string[.z.P]," ",x}
disableLog:{.z.M.log set(::);}
f:{x+1}
// upd:{.z.m.log"updating";select f a from ([]a:1 2 3)}  // would look for `f` in the user's namespace
upd:{.z.m.log"updating";select .z.m.f a from ([]a:1 2 3)}
export:([disableLog;upd])

// user
q)foo:use`foo
q)foo.upd[]
2025.10.07D15:36:13.107844497 updating
a
-
2
3
4
q)f:{x+3}
q)foo.upd[]
2025.10.07D15:36:20.624211098 updating
a
-
2
3
4
q)foo.disableLog[]
q)foo.upd[]
a
-
2
3
4

.z.m is also useful for combining the contents of modules as opposed to forcing one module's exports to live under a single name:
q).z.m,:use`foo

Names formed with .z.M can be passed into legacy APIs that require a global variable name as a symbol.

q).timer.addTimer[.z.M.cleanup;01:00]

Outside a module, .z.m and .z.M refer to the default namespace (.).

The name .z.m can also be used in the \d command to create a child namespace within the module's namespace:
\d .z.m.foo

### Search path

Loading modules supports specifying a search path. If not specified, the search path is $QHOME/mod. The path can be given as a colon-separated list in the environment variable QPATH (in the same manner as the UNIX PATH variable), or at run time in the variable .Q.m.SP which contains a string list.

When loading a module foo, it is searched in turn at every element of the search path using the following file names for the case where .Q.m.SP contains only "mp":

  mp/foo.k
  mp/foo.q
  mp/foo.k_
  mp/foo.q_
  mp/foo.$PLATFORM.so
  mp/foo/init.k
  mp/foo/init.q
  mp/foo/init.k_
  mp/foo/init.q_
  mp/foo/init.$PLATFORM.so

  In case there are multiple paths in .Q.m.SP, each path is checked for all of the above file names before moving on to the next path. The first matching file (in the order listed above) found will be used.

$PLATFORM is a platform identifier that consists of the operating system type (w for Windows, l for Linux and m for Mac), the architecture (i for Intel, a for ARM) and word size (32 or 64). For example, Linux on 64-bit Intel CPU is li64.

### Module hierarchy

It is possible for modules to refer to each other in a hierarchy. A name with a single leading period refers to a child, a name with two leading periods refers to a sibling, a name with three leading periods refers to a paren'ts sibling etc. It is also possible to refer to modules multiple levels down.

An example module tree:

$ tree $QHOME/mod
m
└── parent
    ├── child1.q
    ├── child2
    │   ├── grandchild1.q
    │   ├── grandchild2.q
    │   └── init.q
    └── init.q


// $QHOME/mod/parent/init.q
-1"This is parent";
export:([])

// $QHOME/mod/parent/child1.q
-1"This is child1";
f:{"bbb",x}
export:([f])

// $QHOME/mod/parent/child2/init.q
-1"This is child2";
d:use`.grandchild1
f:{"ccc",d.f x}
export:([f])

// $QHOME/mod/parent/child2/grandchild1.q
-1"This is grandchild1";
e:use`..grandchild2
b:use`...child1
f:{"ddd",b.f e.f x}
export:([f])

// $QHOME/mod/parent/child2/grandchild2.q
-1"This is grandchild2";
f:{"eee",x}
export:([f])

// user
q)([f]):use`parent.child2
This is child2
This is grandchild1
This is grandchild2
This is child1
q)f"aaa"
"cccdddbbbeeeaaa"


### use

As seen above, use returns the module's export such that it can be assigned to one or more variables in the user code. It also replaces any function definitions with aliases:

q)f
`.m.parent.0child2.export.f[]
q)type f
104h

The alias refers to a generated name whose format should not be relied on. The advantage of using an alias is that if the underlying function changes (such as in the .z.M.log set(::) example above), the alias will automatically refer to the changed function, as opposed to retaining the previous value as with a plain assignment.

To programmatically get the definition of the aliased function, use the following idiom:

q)value first value f
{"ccc",d.f x}

use also deduplicates module loads. If a module is used multiple times, perhaps in different modules, it is only loaded once, and the subsequent use calls return a cached value.

// fresh q session
q)f:use`parent.child1
This is child1
q)g:use`parent.child2
This is child2
This is grandchild1
This is grandchild2
// child1 is not loaded twice

Because it is a normal function, use can be used even inside functions, as long as the execution context has the necessary permissions (e.g. a function inside peach cannot load any new modules, but may retrieve an already loaded and cached module).

q)f:{use[`parent.child1][`f]x}
q)f"aaa"
This is child1
"bbbaaa"

### Module-relative file path

A path starting with a double colon is relative to the path of the current module. Since path symbols also start with a colon, this means a module-relative path symbol has three colons. This resolution only works during module load. To use these paths in a function, resolve them at load time using .Q.rp and save the result in a variable.

// $QHOME/mod/foo/init.q
\l ::bar.q
export:([f])

// $QHOME/mod/foo/bar.q
data:.Q.rp`:::bar.txt
f:{read0 data}

// $QHOME/mod/foo/bar.txt
hello world

// user
q)([f]):use`foo
q)f[]
"hello world"

### Converting a legacy library to a module

To convert an existing legacy library to a module, perform the following steps:

q libraries
If the module has any external dependencies, convert those to modules first, then replace the relevant import statements with use.
Remove any absolute namespace name prefixes (e.g. .lib.func to func). This applies to all assignments, global variable references in functions, as well as \d commands (which should be removed if encompassing the entire module, or changed to use namespaces based on .z.m).
If removing the namespace prefix would create a conflict between a local and a global variable, change the global reference to use .z.M (although for code readability, renaming one of the two to be more distinct might be a better idea).
Assignments to globals in functions need to be switched from : to :: to ensure the variable is still recognized as a global.
If a variable name would become invalid because of clashing with a reserved word (e.g. a function named use, log or parse), prefix it with .z.m.
Similarly, use the .z.m prefix for any global functions used by q-sql statements.
Convert any relative paths to use the :: prefix.
Add an export global variable at the end of the module. This should be a dictionary containing the public interface of the module. For simple modules with no internal variables and functions, export:.z.m to export everything might suffice.
Rename the module file to one of the file names supported by lookup (for a module m, this will typically be either m.q or m/init.q).
In the user code, make sure that the path to the module is on $QPATH, and replace the import statement with use.

### Binary libraries

Add a function named kexport that returns a dictionary containing the public interface functions of the module. See the export variable above for an example.
Rename the library file to one of the file names supported by lookup (for a module m on Intel 64-bit Linux, this will typically be either m.li64.so or m/init.li64.so).
In the user code, make sure that the path to the library is on $QPATH, and replace the import statement with use.