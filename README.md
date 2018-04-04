# zerkenv

Zerkenv is a simple CLI tool for managing environment variables.

* Built around the idea of sets of environment variables, called _modules_.
* Modules can depend on other modules, allowing one to set up _environments_.
* Modules can be shared &mdash; these are stored in S3 and cached in local files.
* Modules can be private &mdash; these are only stored in local files.
* Local module files are encrypted at all times &mdash; at rest and in flight.

## Install

First, make sure you have the following tools installed and configured:

* [`aws`][aws] &mdash; protip: you can use `zerkenv` to manage AWS credentials!
* [`gpg`][gpg] &mdash; you'll probably want to make sure `gpg-agent` is
  configured correctly, too.

> If you're using Mac OS X, there may be some additional setup to do -- see
> [Troubleshooting - OS X](#osx) below.

Then, download the [`zerkenv`][zerkenv] script to a directory in your `PATH`.

```bash
curl -fsSL https://raw.githubusercontent.com/adzerk-oss/zerkenv/master/zerkenv > ~/bin/zerkenv
chmod 755 ~/bin/zerkenv
```

Finally, to configure `zerkenv` for your shell do the following (or skip to the
section for your shell below):

* Set the `ZERKENV_BUCKET` environment variable to your S3 bucket.
* Optionally set the `ZERKENV_DIR` environment variable to your local cache dir.
* Configure your shell to evaluate the output of `zerkenv -i <shell>` on
  startup.

#### Bash

Add the following to your `~/.bashrc` file:

```bash
export ZERKENV_BUCKET=my-zerkenv-modules  # set this to your s3 bucket name
export ZERKENV_DIR=$HOME/.config/zerkenv  # optional: default is ~/.zerkenv
. <(zerkenv -i bash)
```

#### Fish

Zerkenv works with Fish shell provided that you have [`bass`] installed. This is
necessary in order to source Bash scripts that set environment variables in the
Bash subprocess, and have those changes reflected in the Fish shell.

After installing [`bass`], add the following to your
`~/.config/fish/config.fish` file:

```fish
set -gx ZERKENV_BUCKET my-zerkenv-modules  # set this to your s3 bucket name
set -gx ZERKENV_DIR $HOME/.config/zerkenv  # optional: default is ~/.zerkenv
. (zerkenv -i fish | psub)
```

## Usage

When correctly installed, you will have two new commands:

* The `zerkenv` command is used to list, create, update, and delete modules.
* The `zerkload` function is used to load modules into the current shell.

Both of these will include tab-completion in your shell, and you can see the
usage info for either with the `-h` option.

```bash
# show usage info
zerkenv -h
```

```bash
# show usage info
zerkload -h
```

The first thing you can do is safely store your AWS credentials in a local
encrypted file for use with `zerkenv`. To do this you will **create a local
module** that is **private**, named `@aws-creds`:

```bash
# Create or replace the local '@aws-creds' module with content from stdin.
# NOTE: Modules whose names start with '@' are PRIVATE modules -- zerkenv
#       will refuse to up/download private modules to/from S3.
cat <<EOT |zerkenv -w @aws-creds
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
EOT
```

Now you can **list the available modules** in the local cache:

```bash
# Print the names or avilable local modules, one per line.
zerkenv -l
```

And you can **print the module contents**:

```bash
# Print the contents of the '@aws-creds' module on stdout.
zerkenv @aws-creds
```

You can **load the module** into your shell:

```bash
# Load the '@aws-creds' module into a new subshell.
zerkload -n @aws-creds
```

```bash
# Load the '@aws-creds' module into the current shell environment.
zerkload @aws-creds
```

You will now see `@aws-creds` when you **list the currently loaded modules**:

```bash
# Print a list of modules loaded into the current shell, one per line.
zerkenv
```

Now let's create a **shared** module. First create it locally, as above, but
choose a name that does not begin with `@`:

```bash
cat <<EOT |zerkenv -w wifi
export WIFI_SSID=guest
export WIFI_PASS=guest
EOT
```

Then, you can **upload the module** from the local cache to S3:

```bash
# Upload the 'wifi' module to S3.
zerkenv -W wifi
```

Now you will see it when you **list the available modules** in S3:

```bash
# List modules available in S3.
zerkenv -r
```

If others have made changes and uploaded them you can **update the local cache**
from S3:

```bash
# Update modules in local cache from S3.
zerkenv -u
```

Finally, you can **delete the module** from the local cache:

```bash
# Delete the 'wifi' module from the local cache.
zerkenv -x wifi
```

and from S3:

```bash
# Delete the 'wifi' module from S3.
zerkenv -X wifi
```

## Modules

Modules are snippets of bash to be evaluated in the current shell context
by the `zerkload` function. A module normally exists to `export` environment
variables, but you can have pretty much any valid bash statements in there.

For example, a typical module:

```bash
export WIFI_SSID=guest
export WIFI_PASS=guest
```

Note that modules are bash snippets, so they may contain references, etc:

```bash
export WIFI_SSID=guest
export WIFI_PASS=guest
export OTHER_WIFI_SSID=$WIFI_SSID
export OTHER_WIFI_PASS=$WIFI_PASS
```

### Dependencies

Modules may declare dependencies on other modules by setting a special
variable named `ZERKENV_DEPENDENCIES`. When `zerkenv` loads module that
declares dependencies into a shell it will also load the dependencies
(in dependency order).

For example:

```bash
ZERKENV_DEPENDENCIES="foo bar baz"
export WIFI_SSID=guest
export WIFI_PASS=guest
```

Modules may contain references to variables defined in dependencies, too:

```bash
ZERKENV_DEPENDENCIES="foo bar"
export BAZ_USER=${FOO_USER:-foop} # use FOO_USER if set, otherwise 'foop'
export BAZ_PASS=${FOO_PASS:-barp} # use FOO_PASS if set, otherwise 'barp'
```

> **Note:** Dependency order is meaningless when the dependency graph has
> cycles. In this case a warning is printed to `stderr` showing the cyclic
> dependencies and the order is chosen arbitrarily.

### Non-Idempotent Actions

Modules may contain arbitrary bash statements. However, the module will be
evaluated twice &mdash; first in a subshell to resolve dependencies, then
again in the current shell.

You may wrap non-idempotent actions in a guard to prevent them from being
evaluated during dependency resolution:

```bash
export FOO=bar
# This prevents 'ssh-add' from being evaluated in the subshell:
if [ -z "$ZERKENV_RESOLVING_DEPENDENCIES" ]; then
  ssh-add ~/.ssh/foo.pem
fi
```

## Troubleshooting

### OS X

#### `envsubst` not installed by default

Zerkenv relies on the `envsubst` program from the `gettext` package, which is
not installed by default on some versions of OS X. If you do not have `envsubst`
available, see [this StackOverflow question][osx-gettext-so] about installing
the `gettext` package on OS X. There is a package available via Homebrew.

#### `gpg` and `gpg-agent` issues

You might run into issues where `gpg-agent` cannot ask for your GPG passphrase
out of the box because it is not configured to know how to do that. It needs a
GUI program like `pinentry` (which is not installed by default on some versions
of OS X) to ask you for your passphrase.

You may find [this guide][osx-gpg-agent-pinentry] to setting up `gpg`,
`gpg-agent`, and `pinentry-mac` useful if you are experiencing problems.

## License

Copyright © 2017-2018 Adzerk

Distributed under the Eclipse Public License version 1.0.

[aws]: https://aws.amazon.com/cli/
[gpg]: https://www.gnupg.org/
[zerkenv]: https://raw.githubusercontent.com/adzerk-oss/zerkenv/master/zerkenv
[bass]: https://github.com/edc/bass
[osx-gettext-so]: https://stackoverflow.com/questions/14940383/how-to-install-gettext-on-macos-x
[osx-gpg-agent-pinentry]: https://www.binarybabel.org/2017/03/10/setting-up-pin-entry-for-gpg-under-macos/
