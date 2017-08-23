# zerkenv

* Simple CLI tool for managing shared environment variables via Amazon S3.
* Built around the idea of sets of environment variables, called _modules_.
* Modules can depend on other modules, allowing one to set up _environments_
  composed of distinct modules.

## Prerequisites

* [`aws`](https://aws.amazon.com/cli/)
* [`parallel`](https://www.gnu.org/software/parallel/)

## Setup

By design, running a shell script cannot affect the shell in which the script
was run. Any variables that are set (or even exported) will not be set in the
shell environment after the script exits:

```bash
$ cat /tmp/myscript.sh
#!/bin/sh

export FOOB=42
$ /tmp/myscript.sh
$ echo $FOOB

$
```

But in this case, that's exactly what we want to do!

For a script to affect the environment of the shell running, the script has to
be sourced:

```bash
$ . /tmp/myscript.sh
$ echo $FOOB
42
$
```

So, to use `zerkenv`, set up an alias that sources `zerkenv.sh`:

```bash
# bash
alias zerkenv=". path/to/zerkenv.sh"
```

```fish
# fish (requires bass: https://github.com/edc/bass)
alias zerkenv "bass . /path/to/zerkenv.sh"
```

Then, set `ZERKENV_BUCKET` to the name of the S3 bucket that you want to use for
storing and retrieving modules.

## Usage

### Uploading a module

```bash
$ cat foo.sh | zerkenv -u foo.sh
```

### Downloading a module

```bash
$ zerkenv -d foo.sh > foo.sh
```

### Listing available modules

```bash
$ zerkenv -l
```

### Sourcing modules

```bash
$ zerkenv -s foo,bar,baz
```

### Seeing what modules have been sourced

`zerkenv` keeps track of which modules you source and adds them to a multiline
environment variable called `ZERKENV_MODULES`.

```bash
$ echo -e "$ZERKENV_MODULES"
foo
bar
baz
```

### Managing dependencies

A `zerkenv` module consists of at least a `<module-name>.sh` file. This is an
`sh` script that will be sourced by `zerkenv` when the module is loaded.

Optionally, a module can also include a `<module-name>.deps` file. This is a
one-line file consisting of a comma-separated list of modules that are the
dependencies of this module. For example, a `foobar` module might look like
this:

foobar.sh:

```bash
#!/bin/sh

export FOOBAR="$FOO $BAR"
```

foobar.deps:

```
foo,bar
```

This example module depends on two other modules, `foo` and `bar`:

foo.sh:

```bash
#!/bin/sh

export FOO=42
```

bar.sh:

```bash
#!/bin/sh

export BAR=43
```

## License

Copyright © 2017 Adzerk

Distributed under the Eclipse Public License version 1.0.
